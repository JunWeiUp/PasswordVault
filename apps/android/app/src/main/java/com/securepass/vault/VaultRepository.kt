package com.securepass.vault

import android.app.Application
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
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
    private val clock: () -> Long = { SystemClock.elapsedRealtime() },
) {
    internal val relay by lazy { PersonalRelay(directory, this) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val legacySource = File(context.applicationInfo.dataDir, "app_flutter/db.sqlite")
    private var closing: Job? = null
    private var session: VaultSession? = null
    private val mutable = MutableStateFlow(VaultState())
    val state = mutable.asStateFlow()
    @Volatile private var epoch = 0
    private var volatileRecovery: String? = null
    @Volatile var captureRichDraft: (() -> Deferred<String?>)? = null
    @Volatile var pendingDraft: String? = null
    private val draftFileLock = Any()
    @Volatile private var lastActivity = clock()
    private var copied: ClipData? = null
    /** Class name of the last failed mutation (e.g. "Storage"); never a message or field value. */
    @Volatile var lastFailureKind: String? = null
        private set

    private val screenLockReceiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action == Intent.ACTION_SCREEN_OFF) lock()
            }
        }

    init {
        scope.launch { state.collect { relay.setUnlocked(it.unlocked) } }
        ContextCompat.registerReceiver(
            context.applicationContext,
            screenLockReceiver,
            IntentFilter(Intent.ACTION_SCREEN_OFF),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        scope.launch {
            mutex.withLock {
                try {
                    directory.mkdirs()
                    session = VaultSession(directory.absolutePath)
                    mutable.value =
                        mutable.value.copy(
                            ready = true,
                            exists = raw(CoreRequest.status()).optBoolean("exists"),
                            legacyAvailable =
                                !raw(CoreRequest.status()).optBoolean("exists") && legacySource.exists(),
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

    /** Sends one typed [CoreRequest]; rich-note ops always carry `richNotes=true`. */
    private fun raw(request: JSONObject): JSONObject {
        if (request.getString("op") in listOf("export", "import", "create-from-backup", "remove", "save")) request.put("richNotes", true)
        return JSONObject(session!!.command(request.toString()))
    }

    /** Body-only and transient fields; all other fields must match before a hydrated note is
     *  reused for an incoming summary (same rule as desktop `summaryKey`). `updatedAt` alone
     *  has one-second resolution, so same-second favourite/move/trash would show stale data. */
    private fun summaryKey(item: JSONObject): String {
        val fields = java.util.TreeMap<String, String>()
        for (key in item.keys()) {
            if (key !in SUMMARY_ONLY && !key.startsWith("_")) fields[key] = item.get(key).toString()
        }
        return fields.toString()
    }

    private fun reload() {
        val generation = epoch
        val data = raw(CoreRequest.list(summaries = true))
        val incoming = data.getJSONArray("items").objects()
        mutable.update { previous ->
            if (generation == epoch) {
                val hydratedById = previous.entries
                    .filter { !it.optBoolean("noteSummary") && it.optString("type") == "secureNote" }
                    .associateBy { it.optString("id") }
                val merged = incoming.map { item ->
                    val id = item.optString("id")
                    val cached = hydratedById[id]
                    if (cached != null && item.optBoolean("noteSummary") && summaryKey(cached) == summaryKey(item)) {
                        cached
                    } else {
                        item
                    }
                }
                previous.copy(
                    entries = merged,
                    settings = data.getJSONObject("settings"),
                    sharedVaults = data.optJSONArray("sharedVaults")?.objects().orEmpty(),
                    sharedMembers = data.optJSONArray("sharedMembers")?.objects().orEmpty(),
                )
            } else previous
        }
    }

    /** Hydrates one lazy `secureNote` summary on demand (`op: "get"`) and updates in-memory state. */
    suspend fun loadFullNote(id: String): JSONObject? {
        if (id.isEmpty()) return null
        val existing = state.value.entries.firstOrNull { it.optString("id") == id }
        if (existing != null && !existing.optBoolean("noteSummary")) return existing
        return mutex.withLock {
            if (!mutable.value.unlocked) return@withLock null
            val generation = epoch
            val full = runCatching {
                withContext(Dispatchers.IO) { raw(CoreRequest.get(id)) }
            }.getOrNull() ?: return@withLock null
            if (generation == epoch && mutable.value.unlocked) {
                mutable.update { prev ->
                    prev.copy(entries = prev.entries.map { if (it.optString("id") == id) full else it })
                }
            }
            full
        }
    }

    suspend fun meshConflicts(): List<JSONObject> = runCatching {
        command(CoreRequest.relayMeshConflicts()).optJSONArray("conflicts")?.objects().orEmpty()
    }.getOrDefault(emptyList())

    suspend fun resolveMeshConflict(noteId: String, strategy: String): Boolean =
        mutate(CoreRequest.relayMeshResolveConflict(noteId, strategy = strategy))

    suspend fun close() {
        relay.close()
        closing?.join()
        mutex.withLock {
            try {
                session?.let {
                    raw(CoreRequest.lock())
                    it.close()
                }
            } finally {
                session = null
                mutable.value = VaultState()
                scope.cancel()
                runCatching { context.applicationContext.unregisterReceiver(screenLockReceiver) }
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

    fun foreground() {
        if (context.getSystemService(KeyguardManager::class.java)?.isDeviceLocked == true) lock()
        else { checkIdle(); relay.resume() }
    }

    /** Keep the in-process session until idle expiry; backgrounding is not an unlock. */
    fun background(): Job {
        checkIdle()
        val generation = epoch
        val pending = pendingDraft
        return scope.launch {
            mutex.withLock {
                synchronized(draftFileLock) {
                    // A save/discard or a later lock must not resurrect an old draft.
                    if (
                        state.value.unlocked &&
                            generation == epoch &&
                            pending != null &&
                            pendingDraft == pending
                    ) {
                        try {
                            persistDraft(pending)
                        } catch (_: Exception) {
                            mutable.update {
                                it.copy(
                                    error =
                                        "草稿暂时加密保留在内存，请勿退出，返回后重试 / Encrypted draft remains in memory; return and retry before quitting"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private fun persistDraft(pending: String) {
        val sealed =
            raw(CoreRequest.sealDrafts(JSONArray().put(JSONObject(pending))))
        volatileRecovery = sealed.toString()
        val atomic = android.util.AtomicFile(File(directory, "mobile-draft.sealed"))
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

    fun canWriteLibrary(): Boolean {
        return true
    }
    fun canEdit(item: JSONObject): Boolean {
        if(!canWriteLibrary()) return false
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
                            CoreRequest.createMigrated(
                                source = legacySource.absolutePath,
                                legacyPassword = legacyPassword,
                                salt = salt,
                                password = password,
                            )
                        )
                    } else
                        raw(if (create) CoreRequest.create(password) else CoreRequest.unlock(password))
                    if (generation == epoch) {
                        reload()
                        recoverDraft()
                    } else raw(CoreRequest.lock())
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
                        CoreRequest.createFromBackup(
                            content = content,
                            password = password,
                            backupPassword = backupPassword,
                            kind = kind,
                        )
                    )
                    if (generation == epoch) reload() else raw(CoreRequest.lock())
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

    suspend fun recover(key: String, newPassword: String, archive: String? = null) {
        closing?.join()
        mutex.withLock {
            if (mutable.value.busy || mutable.value.unlocked || newPassword.isEmpty()) return@withLock
            val generation = epoch
            mutable.value = mutable.value.copy(busy = true, error = null)
            try {
                withContext(Dispatchers.IO) {
                    raw(
                        if (archive == null) CoreRequest.recoveryResetPassword(key, newPassword)
                        else CoreRequest.recoveryRestoreBackup(key, archive, newPassword)
                    )
                    if (!BiometricVault.clearAfterRecovery(context)) mutable.value = mutable.value.copy(notice = "恢复成功，请手动关闭并重新设置生物识别 / Recovered; manually disable and re-enroll biometrics")
                    if (generation == epoch) { reload(); if (archive == null) recoverDraft() } else raw(CoreRequest.lock())
                }
                if (generation == epoch) {
                    mutable.value = mutable.value.copy(exists = true, legacyAvailable = false, unlocked = true)
                    activity()
                }
            } catch (_: Exception) {
                if (generation == epoch) {
                    runCatching { withContext(Dispatchers.IO) { raw(CoreRequest.lock()) } }
                    mutable.value = mutable.value.copy(unlocked = false, exists = File(directory, "vault").exists(), error = "恢复未完成，请检查密钥和备份 / Recovery failed; check the key and backup")
                }
            } finally { mutable.value = mutable.value.copy(busy = false) }
        }
    }

    fun lock() {
        val capturedRichDraft = captureRichDraft?.invoke()
        captureRichDraft = null
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
                        val latest = capturedRichDraft?.await() ?: pending
                        if (latest != null) synchronized(draftFileLock) { persistDraft(latest) }
                    } catch (_: Exception) {
                        mutable.value =
                            mutable.value.copy(
                                error =
                                    "草稿暂时加密保留在内存，请勿退出，解锁后重试 / Encrypted draft remains in memory; do not quit. Unlock and retry"
                            )
                    } finally {
                        try {
                            raw(CoreRequest.lock())
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
                raw(CoreRequest.openDrafts(sealed.getJSONObject("payload")))
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
        synchronized(draftFileLock) {
            volatileRecovery = null
            pendingDraft = null
            mutable.value = mutable.value.copy(recoveredDraft = null)
            File(directory, "mobile-draft.sealed").delete()
        }
    }

    suspend fun importNoteAttachment(noteId: String, name: String, mime: String, data: ByteArray): JSONObject = mutex.withLock {
        check(mutable.value.unlocked); JSONObject(session!!.importNoteAttachment(noteId, name, mime, data))
    }
    suspend fun readNoteAttachment(noteId: String, id: String): ByteArray = mutex.withLock {
        check(mutable.value.unlocked); session!!.readNoteAttachment(noteId, id)
    }
    suspend fun discardNoteAttachment(noteId: String, id: String) = mutex.withLock {
        check(mutable.value.unlocked); session!!.discardNoteAttachment(noteId, id)
    }

    suspend fun command(request: JSONObject): JSONObject =
        mutex.withLock {
            val op = request.getString("op")
            check(mutable.value.unlocked) { "Locked" }
            check(pendingDraft == null || op !in listOf("relay-init", "relay-receive", "recovery-export", "history-enable", "history-restore", "history-prune", "share-seal")) { "Save or discard the current draft first" }
            val generation = epoch
            val result = withContext(Dispatchers.IO) { raw(request) }
            check(generation == epoch && mutable.value.unlocked) { "Locked" }
            if (!op.startsWith("relay-") && op !in listOf("totp", "status", "matches", "sync-respond")) activity()
            result
        }

    suspend fun refresh() =
        mutex.withLock { if (mutable.value.unlocked) withContext(Dispatchers.IO) { reload() } }

    suspend fun audit(): JSONArray =
        mutex.withLock {
            check(mutable.value.unlocked)
            withContext(Dispatchers.IO) {
                JSONArray(session!!.command(CoreRequest.audit().toString()))
            }
        }

    suspend fun save(item: JSONObject): Boolean {
        val payload = JSONObject(item.toString())
        if (payload.optBoolean("noteSummary")) {
            val id = payload.optString("id")
            val full = loadFullNote(id) ?: return false
            val merged = JSONObject(full.toString())
            val skip = setOf("noteDocument", "noteOriginal", "note", "noteFormat", "noteSummary", "__noteSearchText")
            val keys = payload.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                if (k !in skip && !k.startsWith("_")) merged.put(k, payload.get(k))
            }
            return mutate(CoreRequest.save(merged.put("updatedAt", Instant.now().toString())))
        }
        return mutate(CoreRequest.save(payload.put("updatedAt", Instant.now().toString())))
    }

    suspend fun mutate(request: JSONObject): Boolean =
        mutex.withLock {
            if (!mutable.value.unlocked || mutable.value.busy) {
                lastFailureKind = if (!mutable.value.unlocked) "Locked" else "Busy"
                return@withLock false
            }
            val generation = epoch
            mutable.value = mutable.value.copy(busy = true)
            lastFailureKind = null
            try {
                withContext(Dispatchers.IO) {
                    raw(request)
                    if (generation == epoch) reload()
                }
                generation == epoch && mutable.value.unlocked
            } catch (failure: Exception) {
                lastFailureKind = failure::class.simpleName ?: "Unknown"
                mutable.value =
                    mutable.value.copy(
                        error = if (failure is com.securepass.vault.core.VaultException.StaleEdit) "此条目已在其他设备修改，草稿保留。请对照新版本后重试 / Entry changed on another device; draft retained. Review the latest version." else "操作未完成，原资料仍保留 / Operation failed; existing data is preserved"
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
            mutate(CoreRequest.remove(item.getString("id")))

    /**
     * Re-checks the master password against the on-disk header without unlocking, writing or
     * changing session state. The derived grant is wiped immediately.
     */
    suspend fun verifyMasterPassword(password: String): Boolean {
        if (password.isEmpty()) return false
        return withContext(Dispatchers.IO) {
            try {
                val grant = com.securepass.vault.core.createBackgroundGrant(directory.absolutePath, password)
                grant.fill(0)
                true
            } catch (_: Exception) {
                false
            }
        }
    }

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
                    } else raw(CoreRequest.lock())
                }
                if (generation == epoch) {
                    mutable.value = mutable.value.copy(unlocked = true)
                    activity()
                }
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
        // Settings › General › Clear clipboard; 0 keeps the clip until the vault locks.
        val seconds = AppPreferences.clipboardSeconds(context)
        mutable.value = mutable.value.copy(notice = AppPreferences.copiedNotice(seconds))
        if (seconds > 0)
            Handler(Looper.getMainLooper())
                .postDelayed({ if (copied === clip) clearClipboard() }, seconds * 1_000L)
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
        private val SUMMARY_ONLY = setOf("noteDocument", "noteOriginal", "noteSummary", "__noteSearchText")
        fun blank(type: String) =
            JSONObject()
                .put("id", UUID.randomUUID().toString())
                .put("type", type)
                .put("card", JSONObject())
                .put("identity", JSONObject())
                .put("title", "")
                .put("note", "")
                .put("period", 30)
                .put("tags", JSONArray())
                .put("noteFormat", "markdown")
                .put("isDeleted", false)
    }
}

fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
