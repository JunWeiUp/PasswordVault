package com.securepass.vault

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.securepass.vault.core.VaultSession
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject

class VaultApplication : Application() {
    val vault by lazy { VaultRepository(this) }
}

data class VaultState(
    val ready: Boolean = false,
    val exists: Boolean = false,
    val legacyAvailable: Boolean = false,
    val unlocked: Boolean = false,
    val busy: Boolean = false,
    val entries: List<JSONObject> = emptyList(),
    val settings: JSONObject = JSONObject(),
    val sharedVaults: List<JSONObject> = emptyList(),
    val sharedMembers: List<JSONObject> = emptyList(),
    val error: String? = null,
    val notice: String? = null,
    val recoveredDraft: String? = null,
)

class VaultRepository(
    private val context: Context,
    private val directory: File = File(context.noBackupFilesDir, "vault-v2"),
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val legacySource = File(context.applicationInfo.dataDir, "app_flutter/db.sqlite")
    val sync by lazy { LocalSync(this, context) }
    private var closing: Job? = null
    private var session: VaultSession? = null
    private val mutable = MutableStateFlow(VaultState())
    val state = mutable.asStateFlow()
    @Volatile private var epoch = 0
    private var volatileRecovery: String? = null
    var systemFileFlow = false
    var pendingDraft: String? = null
    private var lastActivity = clock()
    private var copied: ClipData? = null

    init {
        scope.launch {
            mutex.withLock {
                try {
                    directory.mkdirs()
                    session = VaultSession(directory.absolutePath)
                    mutable.value =
                        mutable.value.copy(
                            ready = true,
                            exists = raw("status").optBoolean("exists"),
                            legacyAvailable =
                                !raw("status").optBoolean("exists") && legacySource.exists(),
                        )
                } catch (_: Exception) {
                    mutable.value =
                        mutable.value.copy(ready = true, error = "无法打开资料库 / Could not open vault")
                }
            }
        }
        scope.launch {
            while (isActive) {
                delay(10_000)
                checkIdle()
            }
        }
    }

    private fun raw(op: String, values: JSONObject = JSONObject()): JSONObject {
        values.put("op", op)
        return JSONObject(session!!.command(values.toString()))
    }

    private fun reload() {
        val generation = epoch
        val data = raw("list")
        mutable.update { previous ->
            if (generation == epoch)
                previous.copy(
                    entries = data.getJSONArray("items").objects(),
                    settings = data.getJSONObject("settings"),
                    sharedVaults = data.optJSONArray("sharedVaults")?.objects().orEmpty(),
                    sharedMembers = data.optJSONArray("sharedMembers")?.objects().orEmpty(),
                )
            else previous
        }
    }

    suspend fun close() {
        closing?.join()
        mutex.withLock {
            try {
                session?.let {
                    raw("lock")
                    it.close()
                }
            } finally {
                session = null
                mutable.value = VaultState()
                scope.cancel()
                sync.stop()
            }
        }
    }

    fun clearMessage() {
        mutable.value = mutable.value.copy(error = null, notice = null)
    }

    fun activity() {
        lastActivity = clock()
    }

    fun checkIdle() {
        val s = state.value
        if (
            s.unlocked &&
                clock() - lastActivity >=
                    s.settings.optLong("autoLockMinutes", 60).coerceAtLeast(1) * 60_000
        )
            lock()
    }

    fun canEdit(item: JSONObject): Boolean {
        val shared = item.optString("sharedVaultId")
        if (shared.isEmpty()) return true
        val own =
            state.value.settings.optJSONObject("sharingIdentity")?.optString("publicKey").orEmpty()
        return state.value.sharedMembers.any {
            it.optString("vaultId") == shared &&
                it.optString("userPublicKey") == own &&
                it.optString("role") in listOf("owner", "editor")
        }
    }

    suspend fun authenticate(password: String, create: Boolean, legacyPassword: String = "") {
        closing?.join()
        mutex.withLock {
            if (mutable.value.busy || (create && password.isEmpty())) return@withLock
            mutable.value = mutable.value.copy(busy = true, error = null)
            val generation = epoch
            try {
                withContext(Dispatchers.IO) {
                    if (create && mutable.value.legacyAvailable) {
                        val salt =
                            context
                                .getSharedPreferences("FlutterSharedPreferences", 0)
                                .getString("flutter.master_key_salt", null)
                                ?: error("Missing legacy salt")
                        raw(
                            "create-migrated",
                            JSONObject()
                                .put("source", legacySource.absolutePath)
                                .put("salt", salt)
                                .put("legacyPassword", legacyPassword)
                                .put("password", password),
                        )
                    } else
                        raw(
                            if (create) "create" else "unlock",
                            JSONObject().put("password", password),
                        )
                    if (generation == epoch) {
                        reload()
                        recoverDraft()
                    } else raw("lock")
                }
                if (generation == epoch) {
                    mutable.value =
                        mutable.value.copy(exists = true, legacyAvailable = false, unlocked = true)
                    activity()
                }
            } catch (_: Exception) {
                mutable.value =
                    mutable.value.copy(
                        error = "密码不正确或资料库无法读取 / Incorrect password or unreadable vault"
                    )
            } finally {
                mutable.value = mutable.value.copy(busy = false)
            }
        }
    }

    suspend fun createFromBackup(
        content: String,
        backupPassword: String,
        password: String,
        kind: String,
    ) {
        closing?.join()
        mutex.withLock {
            if (mutable.value.exists || mutable.value.busy) return@withLock
            val generation = epoch
            mutable.value = mutable.value.copy(busy = true, error = null)
            try {
                withContext(Dispatchers.IO) {
                    raw(
                        "create-from-backup",
                        JSONObject()
                            .put("content", content)
                            .put("backupPassword", backupPassword)
                            .put("password", password)
                            .put("kind", kind),
                    )
                    if (generation == epoch) reload() else raw("lock")
                }
                if (generation == epoch) {
                    mutable.value =
                        mutable.value.copy(exists = true, legacyAvailable = false, unlocked = true)
                    activity()
                }
            } catch (_: Exception) {
                mutable.value =
                    mutable.value.copy(
                        error =
                            "备份无法读取，未创建新资料库，原文件保留 / Backup unreadable; no new vault was created. Source retained"
                    )
            } finally {
                mutable.value = mutable.value.copy(busy = false)
            }
        }
    }

    fun lock() {
        sync.stop()
        epoch++
        mutable.value =
            mutable.value.copy(
                unlocked = false,
                entries = emptyList(),
                settings = JSONObject(),
                sharedVaults = emptyList(),
                sharedMembers = emptyList(),
                notice = null,
                error = null,
            )
        clearClipboard()
        val pending = pendingDraft
        pendingDraft = null
        mutable.value = mutable.value.copy(recoveredDraft = null)
        closing =
            scope.launch {
                mutex.withLock {
                    try {
                        if (pending != null) {
                            val sealed =
                                raw(
                                    "seal-drafts",
                                    JSONObject().put("items", JSONArray().put(JSONObject(pending))),
                                )
                            volatileRecovery = sealed.toString()
                            val atomic =
                                android.util.AtomicFile(File(directory, "mobile-draft.sealed"))
                            val stream = atomic.startWrite()
                            try {
                                stream.write(sealed.toString().toByteArray())
                                atomic.finishWrite(stream)
                                volatileRecovery = null
                            } catch (e: Exception) {
                                atomic.failWrite(stream)
                                throw e
                            }
                        }
                    } catch (_: Exception) {
                        mutable.value =
                            mutable.value.copy(
                                error =
                                    "草稿暂时加密保留在内存，请勿退出，解锁后重试 / Encrypted draft remains in memory; do not quit. Unlock and retry"
                            )
                    } finally {
                        try {
                            raw("lock")
                        } catch (_: Exception) {}
                    }
                }
            }
    }

    private fun recoverDraft() {
        val file = File(directory, "mobile-draft.sealed")
        if (!file.exists() && volatileRecovery == null) return
        try {
            val sealed = JSONObject(volatileRecovery ?: file.readText())
            val restored =
                raw("open-drafts", JSONObject().put("payload", sealed.get("payload")))
                    .getJSONArray("items")
            val draft = if (restored.length() > 0) restored.getJSONObject(0).toString() else null
            pendingDraft = draft
            mutable.value = mutable.value.copy(recoveredDraft = draft)
        } catch (_: Exception) {
            mutable.value =
                mutable.value.copy(
                    error = "资料库可正常解锁，但草稿无法读取，草稿文件已保留 / Vault unlocked; unreadable draft retained"
                )
        }
    }

    fun discardDraft() {
        volatileRecovery = null
        pendingDraft = null
        mutable.value = mutable.value.copy(recoveredDraft = null)
        File(directory, "mobile-draft.sealed").delete()
    }

    suspend fun command(op: String, values: JSONObject = JSONObject()): JSONObject =
        mutex.withLock {
            check(mutable.value.unlocked) { "Locked" }
            val generation = epoch
            val result = withContext(Dispatchers.IO) { raw(op, values) }
            check(generation == epoch && mutable.value.unlocked) { "Locked" }
            if (op !in listOf("totp", "status", "matches", "sync-respond")) activity()
            result
        }

    suspend fun refresh() =
        mutex.withLock { if (mutable.value.unlocked) withContext(Dispatchers.IO) { reload() } }

    suspend fun audit(): JSONArray =
        mutex.withLock {
            check(mutable.value.unlocked)
            withContext(Dispatchers.IO) {
                JSONArray(session!!.command(JSONObject().put("op", "audit").toString()))
            }
        }

    suspend fun save(item: JSONObject): Boolean =
        mutate(
            "save",
            JSONObject()
                .put("item", JSONObject(item.toString()).put("updatedAt", Instant.now().toString())),
        )

    suspend fun mutate(op: String, values: JSONObject): Boolean =
        mutex.withLock {
            if (!mutable.value.unlocked || mutable.value.busy) return@withLock false
            val generation = epoch
            mutable.value = mutable.value.copy(busy = true)
            try {
                withContext(Dispatchers.IO) {
                    raw(op, values)
                    if (generation == epoch) reload()
                }
                generation == epoch && mutable.value.unlocked
            } catch (_: Exception) {
                mutable.value =
                    mutable.value.copy(
                        error = "操作未完成，原资料仍保留 / Operation failed; existing data is preserved"
                    )
                false
            } finally {
                mutable.value = mutable.value.copy(busy = false)
            }
        }

    suspend fun trash(item: JSONObject): Boolean =
        save(
            JSONObject(item.toString())
                .put("isDeleted", !item.optBoolean("isDeleted"))
                .put(
                    "deletedAt",
                    if (item.optBoolean("isDeleted")) "" else Instant.now().toString(),
                )
        )

    suspend fun remove(item: JSONObject): Boolean =
        item.optBoolean("isDeleted") &&
            mutate("remove", JSONObject().put("id", item.getString("id")))

    suspend fun biometricKey(): ByteArray =
        mutex.withLock {
            check(mutable.value.unlocked)
            withContext(Dispatchers.IO) { session!!.biometricKey() }
        }

    suspend fun unlockBiometric(key: ByteArray) {
        closing?.join()
        mutex.withLock {
            val generation = epoch
            try {
                withContext(Dispatchers.IO) {
                    session!!.unlockBiometric(key)
                    if (generation == epoch) {
                        reload()
                        recoverDraft()
                    } else raw("lock")
                }
                if (generation == epoch) mutable.value = mutable.value.copy(unlocked = true)
            } finally {
                key.fill(0)
            }
        }
    }

    fun copy(value: String) {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        val clip = ClipData.newPlainText("PasswordVault", value)
        if (android.os.Build.VERSION.SDK_INT >= 33)
            clip.description.extras =
                android.os.PersistableBundle().apply {
                    putBoolean("android.content.extra.IS_SENSITIVE", true)
                }
        clipboard.setPrimaryClip(clip)
        copied = clip
        activity()
        mutable.value = mutable.value.copy(notice = "已复制，30 秒后清除 / Copied; clears in 30 seconds")
        Handler(Looper.getMainLooper())
            .postDelayed({ if (copied === clip) clearClipboard() }, 30_000)
    }

    private fun clearClipboard() {
        val own = copied ?: return
        copied = null
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        val current = clipboard.primaryClip
        if (
            current?.description?.label == own.description.label &&
                current.getItemAt(0).text == own.getItemAt(0).text
        ) {
            if (android.os.Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
            else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }

    fun report() {
        mutable.value =
            mutable.value.copy(error = "操作未完成，请检查输入后重试 / Could not complete; check input and retry")
    }

    companion object {
        fun blank(type: String) =
            JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("type", type)
                .put("title", "")
                .put("note", "")
                .put("period", 30)
                .put("tags", JSONArray())
                .put("noteFormat", "markdown")
                .put("isDeleted", false)
    }
}

fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
