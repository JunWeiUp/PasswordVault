package com.securepass.vault

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.github.junweiup.commonrelay.*
import java.io.File
import java.net.URI
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import org.json.JSONObject

internal data class RelayUi(
    val status: String = "未连接 / Disconnected", val error: String? = null,
    val publicKey: String = "", val device: String = "", val group: String = "", val endpoint: String = "",
    val paired: Boolean = false, val paused: Boolean = true, val pending: Int = 0,
    val reply: String = "", val code: String = "", val lastReceived: Long? = null,
)

internal class PersonalRelay(private val directory: File, private val vault: VaultRepository) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val actions = Mutex()
    private val mutable = MutableStateFlow(RelayUi())
    val state = mutable.asStateFlow()
    private val storage = File(directory, "relay-private")
    private val configFile = File(storage, "identity.sealed")
    private val alias = "pv-relay-" + hex(hash(directory.absolutePath.toByteArray())).take(32)
    private var config: JSONObject? = null
    private var loop: Job? = null
    private var client: RelayClient? = null
    private var journal: RelayJournal? = null
    @Volatile private var unlocked = false
    @Volatile private var epoch = 0
    @Volatile private var wake = false
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()

    init { scope.launch {
        actions.withLock {
            try {
                storage.mkdirs()
                config = if (configFile.exists()) JSONObject(String(decrypt(configFile.readBytes(), key()))) else {
                    JSONObject().put("device", UUID.randomUUID().toString()).put("secret", hex(Crypto.random(32)))
                        .put("group", "").put("hub", "").put("endpoint", "").put("token", "").put("paused", true)
                        .put("peers", JSONObject()).also { save(it) }
                }
                publish(); start()
            } catch (_: Exception) { mutable.value = mutable.value.copy(error = "无法读取中继安全配置 / Secure relay configuration unavailable") }
        }
    } }
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        check(!configFile.exists()) { "Missing key" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build()); generateKey()
        }
    }
    private fun save(value: JSONObject) {
        storage.mkdirs()
        // Android 8 AtomicFile creates the base path in startWrite; obtain/create the
        // Keystore key first so an empty in-progress file is not mistaken for a lost key.
        val sealed = encrypt(value.toString().toByteArray(), key())
        val atomic = android.util.AtomicFile(configFile)
        val output = atomic.startWrite()
        try { output.write(sealed); atomic.finishWrite(output) }
        catch (error: Exception) { atomic.failWrite(output); throw error }
    }
    private fun crypto(value: JSONObject): Crypto {
        val peers = value.getJSONObject("peers")
        return Crypto("passwordvault", value.getString("group"), value.getString("device"),
            value.getString("secret"), peers.keys().asSequence().associateWith { peers.getString(it) })
    }
    private fun publish() {
        val c = config ?: return
        mutable.value = mutable.value.copy(publicKey = crypto(c).publicKey(), device = c.getString("device"),
            group = c.getString("group"), endpoint = c.getString("endpoint"), paired = c.getJSONObject("peers").length() > 0, paused = c.getBoolean("paused"))
    }
    private fun action(block: suspend (JSONObject) -> Unit) { scope.launch {
        actions.withLock {
            try {
                val c = checkNotNull(config); mutable.value = mutable.value.copy(error = null)
                stop(); block(c); save(c); publish(); start()
            } catch (_: Exception) { mutable.value = mutable.value.copy(error = "中继操作失败；请检查凭据、配对和网络 / Relay operation failed") }
        }
    } }
    fun importCredential(text: String, endpoint: String) = action { c ->
        val url = URI(endpoint)
        require(url.scheme == "wss" && url.host != null && url.path == "/relay/v1/ws" && url.rawUserInfo == null && url.query == null && url.fragment == null)
        val credential = JSONObject(text); val own = credential.getJSONObject("identity")
        require(own.getString("app") == "passwordvault" && own.getString("public_key") == crypto(c).publicKey())
        val current = vault.command("relay-status")
        if (current.optBoolean("enabled")) require(current.getString("group") == own.getString("group") && current.getString("device") == own.getString("device"))
        require(credential.getString("token").length >= 32)
        c.put("endpoint", endpoint).put("device", own.getString("device")).put("group", own.getString("group")).put("token", credential.getString("token"))
    }
    fun pair(text: String) = action { c ->
        val invitation = JSONObject(text)
        require(c.getString("token").isNotEmpty() && invitation.getInt("version") == 1 && invitation.getString("group") == c.getString("group") && invitation.getString("endpoint") == c.getString("endpoint"))
        val expiry = invitation.getLong("expires"); val now = System.currentTimeMillis()/1000
        require(expiry > now && expiry <= now + 310)
        val hub = invitation.getString("hub"); val public = invitation.getString("key"); val nonce = invitation.getString("nonce")
        require(Crypto.unhex(public).size == 32)
        val peers = c.getJSONObject("peers")
        require(!peers.has(hub) || peers.getString(hub) == public)
        val current = vault.command("relay-status")
        if (current.optBoolean("enabled")) require(current.getString("hub") == hub && current.getString("group") == c.getString("group"))
        else vault.command("relay-init", JSONObject().put("role", "mobile").put("device", c.getString("device")).put("group", c.getString("group")).put("hub", hub))
        c.put("hub", hub); peers.put(hub, public); save(c)
        vault.command("relay-trust", JSONObject().put("peer", hub))
        val localKey = crypto(c).publicKey()
        mutable.value = mutable.value.copy(code = hex(hash("$nonce\n$public\n$localKey".toByteArray())).take(8).uppercase(),
            reply = JSONObject().put("version", 1).put("group", c.getString("group")).put("device", c.getString("device")).put("key", localKey).put("nonce", nonce).toString())
        c.put("paused", false)
    }
    fun pause(paused: Boolean) = action { it.put("paused", paused) }
    fun unpair() = action { c ->
        val hub = c.getString("hub")
        vault.command("relay-revoke", JSONObject().put("peer", hub)); c.put("peers", JSONObject()).put("paused", true)
        mutable.value = mutable.value.copy(reply = "", code = "")
    }
    fun setUnlocked(value: Boolean) {
        if (value == unlocked) return
        unlocked = value
        if (!value) {
            epoch++; client?.close(); loop?.cancel()
            mutable.value = mutable.value.copy(status = "已锁定 / Locked", reply = "", code = "", pending = 0)
        } else scope.launch { actions.withLock { stop(); start() } }
    }
    suspend fun close() { unlocked = false; stop(); scope.cancel(); http.connectionPool.evictAll() }
    fun syncNow() { wake = true; scope.launch { actions.withLock { if (loop?.isActive != true) start() } } }
    private suspend fun stop() { epoch++; client?.close(); loop?.cancelAndJoin(); loop = null }
    private fun start() {
        val c = config ?: return
        if (!unlocked || c.optBoolean("paused", true) || c.optString("token").isEmpty() || c.getJSONObject("peers").length() == 0) return
        val snapshot = JSONObject(c.toString()); val generation = epoch
        loop = scope.launch { run(snapshot, generation) }
    }
    private suspend fun run(c: JSONObject, generation: Int) {
        var backoff = 1000L
        while (currentCoroutineContext().isActive && unlocked && generation == epoch) {
            var connection: RelayClient? = null
            try {
                if (journal == null) journal = RelayJournal(File(storage, "journal").toPath())
                val crypto = crypto(c); val hub = c.getString("hub")
                val events = Channel<JSONObject>(64); val ready = CompletableDeferred<Unit>()
                connection = RelayClient(http, crypto, object: RelayClient.Listener {
                    override fun onReady() { ready.complete(Unit) }
                    override fun onEvent(event: JSONObject) { if (events.trySend(event).isFailure) events.close(IllegalStateException("Event backlog")) }
                    override fun onClosed(error: Throwable) { ready.completeExceptionally(error); events.close(error) }
                }, journal)
                client = connection
                mutable.value = mutable.value.copy(status = "正在连接 / Connecting")
                connection.connect(c.getString("endpoint"), c.getString("token"))
                withTimeout(45_000) { ready.await() }
                mutable.value = mutable.value.copy(status = "已连接 / Connected", error = null); backoff = 1000
                val fileClient = RelayFiles(http, c.getString("endpoint").replaceFirst("wss://", "https://").removeSuffix("/ws") + "/files", c.getString("token"))
                var last = ""
                while (currentCoroutineContext().isActive && unlocked && generation == epoch) {
                    while (true) {
                        val result = events.tryReceive()
                        if (result.isClosed) throw IllegalStateException("Disconnected")
                        val event = result.getOrNull() ?: break
                        if (event.optString("type") == "message") {
                            require(event.getString("from") == hub)
                            receive(Base64.getDecoder().decode(event.getString("data")), hub, generation)
                            connection.acknowledge(event).get(45, TimeUnit.SECONDS)
                        } else if (event.optString("type") == "peer.up") last = ""
                    }
                    val summary = vault.command("relay-status")
                    mutable.value = mutable.value.copy(pending = summary.optInt("pending"))
                    val packet = vault.command("relay-export", JSONObject().put("peer", hub)).toString().toByteArray()
                    val signature = hex(hash(packet)) + ":" + System.currentTimeMillis()/3_600_000
                    if (last != signature || wake) {
                        wake = false
                        if (packet.size <= 128*1024) connection.message(hub, packet, true, hex(hash((hub + signature).toByteArray())).take(32)).get(45, TimeUnit.SECONDS)
                        else sendFile(packet, crypto, hub, fileClient)
                        last = signature
                    }
                    val inbox = fileClient.inbox()
                    for (index in 0 until inbox.length()) {
                        val file = inbox.getJSONObject(index)
                        require(file.getString("from") == hub && file.getLong("size") <= 768L*1024*1024)
                        val cipher = File(storage, UUID.randomUUID().toString()+".download")
                        val inner = File(storage, UUID.randomUUID().toString()+".sealed")
                        try {
                            fileClient.download(file, cipher)
                            val meta = RelayFiles.decrypt(crypto, hub, file, cipher, inner)
                            require(meta.getString("format") == "passwordvault.sync.v1")
                            receive(decrypt(inner.readBytes(), SecretKeySpec(Crypto.unhex(meta.getString("key")), "AES")), hub, generation)
                            fileClient.acknowledge(file.getString("id"))
                        } finally { cipher.delete(); inner.delete() }
                    }
                    delay(5000)
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { if (unlocked && generation == epoch) mutable.value = mutable.value.copy(status = "等待重连 / Waiting to reconnect", error = "同步未完成，本地改动已保留 / Sync incomplete; local changes retained") }
            finally { connection?.close() }
            delay(backoff); backoff = (backoff*2).coerceAtMost(30_000)
        }
    }
    private suspend fun receive(data: ByteArray, hub: String, generation: Int) {
        check(unlocked && generation == epoch)
        vault.command("relay-receive", JSONObject().put("peer", hub).put("packet", JSONObject(String(data))))
        check(unlocked && generation == epoch)
        vault.refresh(); mutable.value = mutable.value.copy(lastReceived = System.currentTimeMillis())
    }
    private fun sendFile(bytes: ByteArray, crypto: Crypto, hub: String, files: RelayFiles) {
        val key = SecretKeySpec(Crypto.random(32), "AES")
        val inner = File(storage, UUID.randomUUID().toString()+".sealed")
        val outer = File(storage, UUID.randomUUID().toString()+".upload")
        try {
            inner.writeBytes(encrypt(bytes, key))
            val info = RelayFiles.prepare(crypto, hub, inner, outer, JSONObject().put("format", "passwordvault.sync.v1").put("key", hex(key.encoded)))
            files.upload(info, outer)
        } finally { inner.delete(); outer.delete() }
    }
    companion object {
        private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        private fun hex(bytes: ByteArray) = Crypto.hex(bytes)
        private fun encrypt(bytes: ByteArray, key: SecretKey): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.ENCRYPT_MODE, key); iv + doFinal(bytes) }
        private fun decrypt(bytes: ByteArray, key: SecretKey): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run { require(bytes.size >= 28); init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0,12))); doFinal(bytes.copyOfRange(12,bytes.size)) }
    }
}
