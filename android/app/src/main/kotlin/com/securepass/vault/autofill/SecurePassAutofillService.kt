package com.securepass.vault.autofill

import android.app.assist.AssistStructure
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.Build
import android.service.autofill.AutofillService
import android.service.autofill.Dataset
import android.service.autofill.FillCallback
import android.service.autofill.FillRequest
import android.service.autofill.FillResponse
import android.service.autofill.SaveCallback
import android.view.View
import android.view.autofill.AutofillId
import android.view.autofill.AutofillValue
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import android.util.Base64
import android.text.InputType
import java.io.File
import java.net.URI
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

@RequiresApi(Build.VERSION_CODES.O)
class SecurePassAutofillService : AutofillService() {

    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: android.os.CancellationSignal,
        callback: FillCallback,
    ) {
        try {
            val structure = request.fillContexts.lastOrNull()?.structure
            if (structure == null) {
                callback.onSuccess(null)
                return
            }

            val fieldIds = extractFieldIds(structure)
            if (fieldIds.usernameId == null && fieldIds.passwordId == null) {
                callback.onSuccess(null)
                return
            }

            val masterKey = readCachedMasterKey()
            if (masterKey == null) {
                callback.onSuccess(null)
                return
            }

            val webDomain = extractWebDomain(structure)
            val items = loadPasswordItems(masterKey, webDomain)
            if (items.isEmpty()) {
                callback.onSuccess(null)
                return
            }

            val responseBuilder = FillResponse.Builder()
            items.take(20).forEach { item ->
                val presentation = buildPresentation(item)
                val datasetBuilder = Dataset.Builder(presentation)

                fieldIds.usernameId?.let { id ->
                    datasetBuilder.setValue(
                        id,
                        AutofillValue.forText(item.username),
                        presentation,
                    )
                }
                fieldIds.passwordId?.let { id ->
                    datasetBuilder.setValue(
                        id,
                        AutofillValue.forText(item.password),
                        presentation,
                    )
                }

                responseBuilder.addDataset(datasetBuilder.build())
            }

            callback.onSuccess(responseBuilder.build())
        } catch (e: Exception) {
            callback.onFailure(e.message)
        }
    }

    override fun onSaveRequest(request: android.service.autofill.SaveRequest, callback: SaveCallback) {
        callback.onSuccess()
    }

    private fun readCachedMasterKey(): ByteArray? {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val cachedBase64 = prefs.getString("flutter.cached_master_key", null) ?: return null
        return try {
            Base64.decode(cachedBase64, Base64.DEFAULT)
        } catch (e: Exception) {
            null
        }
    }

    private fun loadPasswordItems(masterKey: ByteArray, webDomain: String?): List<VaultItem> {
        val dbFile = File(applicationContext.dataDir, "app_flutter/db.sqlite")
        if (!dbFile.exists()) return emptyList()

        val db = SQLiteDatabase.openDatabase(dbFile.absolutePath, null, SQLiteDatabase.OPEN_READONLY)
        val items = mutableListOf<VaultItem>()
        val cursor = db.query(
            "vault_items",
            arrayOf("title", "username", "password", "url"),
            "type = 0",
            null,
            null,
            null,
            "updated_at DESC",
            "100",
        )

        cursor.use {
            while (it.moveToNext()) {
                val title = it.getString(0) ?: ""
                val username = it.getString(1) ?: ""
                val encryptedPassword = it.getString(2)
                val url = it.getString(3)

                val password = tryDecrypt(encryptedPassword, masterKey) ?: continue
                if (password.isBlank()) continue

                if (webDomain != null && !hostMatches(url, webDomain)) {
                    continue
                }

                items.add(
                    VaultItem(
                        title = title.ifBlank { url ?: "PasswordVault" },
                        username = username,
                        password = password,
                        url = url,
                    )
                )
            }
        }
        db.close()
        return items
    }

    private fun tryDecrypt(encryptedBase64: String?, key: ByteArray): String? {
        if (encryptedBase64.isNullOrBlank()) return null
        return try {
            val data = Base64.decode(encryptedBase64, Base64.DEFAULT)
            if (data.size < 12 + 16) return null
            val nonce = data.copyOfRange(0, 12)
            val tag = data.copyOfRange(data.size - 16, data.size)
            val cipherText = data.copyOfRange(12, data.size - 16)
            val combined = ByteArray(cipherText.size + tag.size)
            System.arraycopy(cipherText, 0, combined, 0, cipherText.size)
            System.arraycopy(tag, 0, combined, cipherText.size, tag.size)

            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            val spec = GCMParameterSpec(128, nonce)
            val secretKey = SecretKeySpec(key, "AES")
            cipher.init(Cipher.DECRYPT_MODE, secretKey, spec)
            val clear = cipher.doFinal(combined)
            String(clear, Charsets.UTF_8)
        } catch (e: Exception) {
            null
        }
    }

    private fun extractWebDomain(structure: AssistStructure): String? {
        val windowCount = structure.windowNodeCount
        for (i in 0 until windowCount) {
            val root = structure.getWindowNodeAt(i).rootViewNode
            val domain = findWebDomain(root)
            if (!domain.isNullOrBlank()) return domain
        }
        return null
    }

    private fun findWebDomain(node: AssistStructure.ViewNode): String? {
        node.webDomain?.let { return it }
        for (i in 0 until node.childCount) {
            val child = node.getChildAt(i)
            val found = findWebDomain(child)
            if (!found.isNullOrBlank()) return found
        }
        return null
    }

    private fun extractFieldIds(structure: AssistStructure): FieldIds {
        val ids = FieldIds(null, null)
        val windowCount = structure.windowNodeCount
        for (i in 0 until windowCount) {
            val root = structure.getWindowNodeAt(i).rootViewNode
            traverseNode(root, ids)
        }
        return ids
    }

    private fun traverseNode(node: AssistStructure.ViewNode, ids: FieldIds) {
        if (node.autofillId != null) {
            val hints = node.autofillHints
            val inputType = node.inputType
            val hint = node.hint?.lowercase() ?: ""
            val idEntry = node.idEntry?.lowercase() ?: ""

            if (ids.passwordId == null && isPasswordField(hints, inputType, hint, idEntry)) {
                ids.passwordId = node.autofillId
            } else if (ids.usernameId == null && isUsernameField(hints, inputType, hint, idEntry)) {
                ids.usernameId = node.autofillId
            }
        }

        for (i in 0 until node.childCount) {
            traverseNode(node.getChildAt(i), ids)
        }
    }

    private fun isPasswordField(
        hints: Array<String>?,
        inputType: Int,
        hint: String,
        idEntry: String,
    ): Boolean {
        if (hints?.any { it == View.AUTOFILL_HINT_PASSWORD } == true) return true
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ||
            hint.contains("password") ||
            idEntry.contains("password")
    }

    private fun isUsernameField(
        hints: Array<String>?,
        inputType: Int,
        hint: String,
        idEntry: String,
    ): Boolean {
        if (hints?.any { it == View.AUTOFILL_HINT_USERNAME || it == View.AUTOFILL_HINT_EMAIL_ADDRESS } == true) {
            return true
        }
        val isEmailType = inputType and InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS
        return isEmailType ||
            hint.contains("user") ||
            hint.contains("email") ||
            hint.contains("login") ||
            idEntry.contains("user") ||
            idEntry.contains("email") ||
            idEntry.contains("login")
    }

    private fun hostMatches(url: String?, origin: String): Boolean {
        val itemHost = extractHost(url) ?: return false
        val originHost = extractHost(origin) ?: return false
        return itemHost == originHost ||
            itemHost.endsWith(".$originHost") ||
            originHost.endsWith(".$itemHost")
    }

    private fun extractHost(rawUrl: String?): String? {
        if (rawUrl.isNullOrBlank()) return null
        return try {
            val trimmed = rawUrl.trim()
            if (!trimmed.contains("://")) {
                return trimmed.split("/").firstOrNull()?.lowercase()
            }
            URI(trimmed).host?.lowercase()
        } catch (e: Exception) {
            rawUrl.trim().lowercase()
        }
    }

    private fun buildPresentation(item: VaultItem): RemoteViews {
        val views = RemoteViews(packageName, android.R.layout.simple_list_item_2)
        views.setTextViewText(android.R.id.text1, item.title)
        val subtitle = if (item.username.isNotBlank()) item.username else (item.url ?: "")
        views.setTextViewText(android.R.id.text2, subtitle)
        return views
    }

    private data class VaultItem(
        val title: String,
        val username: String,
        val password: String,
        val url: String?,
    )

    private data class FieldIds(
        var usernameId: AutofillId?,
        var passwordId: AutofillId?,
    )
}
