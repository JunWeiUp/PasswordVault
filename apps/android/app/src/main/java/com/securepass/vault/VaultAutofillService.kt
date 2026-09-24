package com.securepass.vault

import android.app.PendingIntent
import android.app.assist.AssistStructure
import android.content.Intent
import android.os.Build
import android.os.CancellationSignal
import android.service.autofill.*
import android.view.View
import android.view.autofill.AutofillId
import android.widget.RemoteViews
import androidx.annotation.RequiresApi
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

@RequiresApi(26)
data class FillTarget(
    val packageName: String,
    val domain: String?,
    val userId: AutofillId?,
    val passwordId: AutofillId,
    val created: Long = android.os.SystemClock.elapsedRealtime(),
    val saveUser: String? = null,
    val savePassword: String? = null,
)

@RequiresApi(26)
object FillRequests {
    private val pending = ConcurrentHashMap<String, FillTarget>()

    fun put(target: FillTarget): String? {
        pending.entries.removeIf {
            android.os.SystemClock.elapsedRealtime() - it.value.created > 120_000
        }
        if (pending.size >= 32) return null
        return UUID.randomUUID().toString().also { pending[it] = target }
    }

    fun get(token: String): FillTarget? =
        pending[token]?.takeIf { android.os.SystemClock.elapsedRealtime() - it.created < 120_000 }

    fun remove(token: String) {
        pending.remove(token)
    }
}

@RequiresApi(26)
class VaultAutofillService : AutofillService() {
    override fun onFillRequest(
        request: FillRequest,
        cancellationSignal: CancellationSignal,
        callback: FillCallback,
    ) {
        val structure =
            request.fillContexts.lastOrNull()?.structure ?: return callback.onSuccess(null)
        val target = parse(structure) ?: return callback.onSuccess(null)
        val token = FillRequests.put(target) ?: return callback.onSuccess(null)
        cancellationSignal.setOnCancelListener { FillRequests.remove(token) }
        val view =
            RemoteViews(packageName, android.R.layout.simple_list_item_1).apply {
                setTextViewText(android.R.id.text1, "PasswordVault · 解锁并选择 / Unlock & choose")
            }
        val intent = Intent(this, AutofillActivity::class.java).putExtra("token", token)
        val pending =
            PendingIntent.getActivity(
                this,
                token.hashCode(),
                intent,
                PendingIntent.FLAG_CANCEL_CURRENT or
                    if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0,
            )
        val locked =
            Dataset.Builder(view)
                .setValue(target.passwordId, null as android.view.autofill.AutofillValue?)
                .setAuthentication(pending.intentSender)
        target.userId?.let { locked.setValue(it, null as android.view.autofill.AutofillValue?) }
        val response =
            FillResponse.Builder()
                .addDataset(locked.build())
                .setSaveInfo(
                    SaveInfo.Builder(SaveInfo.SAVE_DATA_TYPE_PASSWORD, arrayOf(target.passwordId))
                        .apply { target.userId?.let { setOptionalIds(arrayOf(it)) } }
                        .build()
                )
                .build()
        if (!cancellationSignal.isCanceled) callback.onSuccess(response)
    }

    override fun onSaveRequest(request: SaveRequest, callback: SaveCallback) {
        val structure =
            request.fillContexts.lastOrNull()?.structure
                ?: return callback.onFailure("无法读取登录表单 / Unable to read form")
        val target =
            parse(structure, save = true)
                ?: return callback.onFailure("未发现密码字段 / No password field")
        val token =
            FillRequests.put(target) ?: return callback.onFailure("请求过多，请重试 / Retry shortly")
        val intent = Intent(this, AutofillActivity::class.java).putExtra("token", token)
        val pending =
            PendingIntent.getActivity(
                this,
                token.hashCode(),
                intent,
                PendingIntent.FLAG_CANCEL_CURRENT or
                    if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0,
            )
        if (Build.VERSION.SDK_INT >= 28) callback.onSuccess(pending.intentSender)
        else {
            FillRequests.remove(token)
            callback.onFailure("请打开 PasswordVault 手动保存 / Open PasswordVault to save manually")
        }
    }

    private fun parse(structure: AssistStructure, save: Boolean = false): FillTarget? {
        var user: AssistStructure.ViewNode? = null
        var password: AssistStructure.ViewNode? = null
        var domain: String? = null
        fun visit(node: AssistStructure.ViewNode) {
            val hints = node.autofillHints?.map { it.lowercase() }.orEmpty()
            val input = node.inputType and android.text.InputType.TYPE_MASK_VARIATION
            if (node.autofillId != null && node.visibility == View.VISIBLE) {
                if (
                    hints.any { it.contains("password") } ||
                        input in
                            listOf(
                                android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD,
                                android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
                                android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD,
                            )
                )
                    password = node
                else if (
                    hints.any { it in listOf("username", "emailaddress", "email", "newusername") }
                )
                    user = node
            }
            if (!node.webDomain.isNullOrBlank()) domain = node.webDomain
            for (i in 0 until node.childCount) visit(node.getChildAt(i))
        }
        for (i in 0 until structure.windowNodeCount) visit(
            structure.getWindowNodeAt(i).rootViewNode
        )
        val secret = password ?: return null
        return FillTarget(
            structure.activityComponent.packageName,
            domain,
            user?.autofillId,
            secret.autofillId!!,
            saveUser = if (save) user?.autofillValue?.textValue?.toString().orEmpty() else null,
            savePassword = if (save) secret.autofillValue?.textValue?.toString().orEmpty() else null,
        )
    }
}
