package com.securepass.vault

import io.github.junweiup.commonrelay.*
import java.io.File
import java.net.URI
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
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

internal data class RelayMember(val id: String, val name: String, val manager: Boolean, val online: Boolean)

internal data class RelayUi(
    val peerLibrary: String = "", val peerConflicts: String = "{}", val peerLibraries: String = "[]", val activePeerLibrary: String = "", val peerRole: String = "blocked", val peerFrozen: Boolean = false, val peerPending: Boolean = false, val peerDevice: String = "",
    val credentialsBlocked: Boolean = false, val automaticJoin: Boolean = false, val managed: Boolean = false, val legacy: Boolean = false, val joining: Boolean = false, val creating: Boolean = false,
    val draftGroupName: String = "", val draftDeviceName: String = "",
    val invalid: Boolean = false, val busy: Boolean = false, val groupFresh: Boolean = false, val groupName: String = "",
    val members: List<RelayMember> = emptyList(), val groupInvite: String = "", val groupCode: String = "", val applicant: String = "",
    val status: String = "未连接 / Disconnected", val error: String? = null,
    val publicKey: String = "", val device: String = "", val group: String = "", val endpoint: String = "",
    val paired: Boolean = false, val paused: Boolean = true, val pending: Int = 0, val conflicts: Int = 0,
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
    private val peerRosters = mutableMapOf<String, JSONObject>()
    private var loop: Job? = null
    private var client: RelayClient? = null
    private var journal: RelayJournal? = null
    @Volatile private var unlocked = false
    @Volatile private var epoch = 0
    @Volatile private var wake = false
    @Volatile private var transportFailure: String? = null
    private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()

    private fun legacyKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return ks.getKey(alias, null) as? SecretKey ?: error("Legacy relay key unavailable")
    }
    private suspend fun loadCredentials() {
        if (!unlocked) return
        val generation = epoch
        mutable.value = mutable.value.copy(busy = true, error = null)
        try {
            val stored = vault.command("relay-credentials-read")
            check(unlocked && generation == epoch)
            val migrating = stored.isNull("data")
            val legacyExists = migrating && configFile.exists()
            val loaded = if (!migrating) JSONObject(stored.getString("data"))
            else if (configFile.exists()) JSONObject(String(decrypt(configFile.readBytes(), legacyKey())))
            else JSONObject().put("device", UUID.randomUUID().toString()).put("secret", hex(Crypto.random(32)))
                .put("group", "").put("hub", "").put("endpoint", "").put("token", "").put("paused", true)
                .put("peers", JSONObject())
            crypto(loaded).publicKey() // Validate legacy identity before committing migration.
            if (migrating) {
                val encoded = loaded.toString()
                vault.command("relay-credentials-write", JSONObject().put("data", encoded))
                check(vault.command("relay-credentials-read").getString("data") == encoded)
            }
            check(unlocked && generation == epoch)
            config = loaded
            if (legacyExists && configFile.delete()) {
                runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) } }
            }
            mutable.value = mutable.value.copy(credentialsBlocked = false)
            publish()
            val summary = vault.command("relay-status")
            mutable.value = mutable.value.copy(pending = summary.optInt("pending"), conflicts = summary.optInt("conflictCount"))
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) {
            if (unlocked && generation == epoch) {
                config = null
                mutable.value = mutable.value.copy(credentialsBlocked = true,
                    error = "中继凭据读取或迁移失败；原接入与加密文件保留 / Relay credential migration/read failed; original access and encrypted files preserved")
            }
        } finally { if (generation == epoch) mutable.value = mutable.value.copy(busy = false) }
    }
    fun retryCredentials() { scope.launch { actions.withLock { stop(); loadCredentials(); start() } } }
    private suspend fun save(value: JSONObject) {
        check(unlocked)
        vault.command("relay-credentials-write", JSONObject().put("data", value.toString()))
    }
    private fun crypto(value: JSONObject): Crypto {
        val peers = value.optJSONObject("groups")?.optJSONObject("trusted_peers") ?: value.getJSONObject("peers")
        return Crypto("passwordvault", value.getString("group"), value.getString("device"),
            value.getString("secret"), peers.keys().asSequence().associateWith { peers.getString(it) })
    }
    private fun publish() {
        val c = config ?: return
        val g = c.optJSONObject("groups")
        val request = g?.optJSONObject("pending_join")?.optJSONObject("request") ?: g?.optJSONObject("join_request")
        val code = request?.let { RelayGroups.digest(RelayGroups.payload(it)).take(12).uppercase().chunked(4).joinToString("-") }.orEmpty()
        val inv = g?.optJSONObject("issued_invitation")
        val creation = g?.optJSONObject("pending_create")?.let { RelayGroups.unpack(it) }
        mutable.value = mutable.value.copy(managed = g?.has("group_entry") == true, legacy = g == null && c.optString("token").isNotEmpty(),
            automaticJoin = (g?.optJSONObject("pending_join")?.optJSONObject("invitation") ?: inv)?.optString("mode") == "auto",
            draftGroupName = creation?.optString("name").orEmpty(), draftDeviceName = creation?.optJSONArray("members")?.optJSONObject(0)?.optString("name").orEmpty(),
            joining = g?.has("pending_join") == true, creating = g?.has("pending_create") == true, invalid = g?.optBoolean("access_invalid") == true,
            groupInvite = if (mutable.value.groupFresh && inv != null && inv.optLong("expires") > System.currentTimeMillis()/1000) inv.optString("short_link").ifEmpty { inv.toString() } else "",
            groupCode = code, applicant = if (mutable.value.groupFresh) g?.optJSONObject("join_request")?.let { RelayGroups.unpack(it).getJSONObject("member").getString("name") }.orEmpty() else "")
        mutable.value = mutable.value.copy(peerLibrary = c.optString("peerLibrary"), peerPending = c.has("peerExpectedLibrary"), publicKey = crypto(c).publicKey(), device = c.getString("device"),
            group = c.getString("group"), endpoint = if (creation != null) g.getString("url") else c.getString("endpoint"), paired = c.getJSONObject("peers").length() > 0, paused = c.getBoolean("paused"))
    }
    private fun action(block: suspend (JSONObject) -> Unit) { scope.launch {
        actions.withLock {
            try {
                val c = checkNotNull(config); mutable.value = mutable.value.copy(error = null)
                stop(); block(c); save(c); publish(); start()
            } catch (_: Exception) { mutable.value = mutable.value.copy(error = "中继操作失败；请检查凭据、配对和网络 / Relay operation failed") }
        }
    } }
    private suspend fun peerSummary(c: JSONObject): JSONObject {
        val state = vault.command("relay-peer-status", JSONObject().put("library", c.getString("peerLibrary")))
        val listing = vault.command("relay-peer-list"); val libraries = listing.getJSONArray("libraries")
        val own=state.optJSONObject("members")?.optJSONObject(state.optString("device"))
        mutable.value=mutable.value.copy(peerRole=if(own?.optString("publicKey")==state.optString("publicKey")) own.optString("role","blocked") else "blocked",peerFrozen=state.optBoolean("frozen"),peerDevice=state.optString("device"),peerPending=c.has("peerExpectedLibrary"))
        mutable.value = mutable.value.copy(peerLibrary=c.optString("peerLibrary"),peerLibraries=libraries.toString(),activePeerLibrary=listing.optString("active").takeUnless { it == "null" }.orEmpty())
        val peers = if (c.has("peerExpectedLibrary")) JSONObject(c.getJSONObject("peers").toString()) else JSONObject()
        val transportRoster = c.optJSONObject("groups")?.optJSONObject("trusted_peers")
        peerRosters.clear()
        for (index in 0 until libraries.length()) {
            val id=libraries.getJSONObject(index).getString("id")
            if (id.startsWith("pending-")) continue
            val details=vault.command("relay-peer-status",JSONObject().put("library",id))
            val members=details.optJSONObject("members") ?: continue
            if(details.optBoolean("frozen") || !members.has(c.getString("device"))) continue
            peerRosters[id]=members
            for(peer in members.keys().asSequence()) {
                val key=members.getJSONObject(peer).optString("transportKey")
                if(peer!=c.getString("device") && key.isNotEmpty() && (transportRoster==null || transportRoster.optString(peer)==key)) peers.put(peer,key)
            }
        }
        c.put("peers",peers);config=c;save(c);return state
    }
    fun switchPeerLibrary(id:String)=action { c ->
        vault.command("relay-peer-switch",JSONObject().put("library",id))
        if(id.isNotEmpty()) c.put("peerLibrary",id)
        peerSummary(c);vault.refresh()
    }
    fun createPeerLibrary(personal: Boolean = true, name: String = "Family library") = action { c ->
        require(c.optString("group").isNotEmpty() && (!personal || !c.has("peerLibrary")))
        val result = vault.command("relay-peer-create", JSONObject().put("device", c.getString("device")).put("personal", personal).put("transportKey", crypto(c).publicKey()).put("migrateLegacy", true).put("name",name))
        c.put("peerLibrary", result.getString("library")).put("peers", JSONObject()).put("paused", false)
        if(!personal) {vault.command("relay-peer-switch",JSONObject().put("library",result.getString("library")));vault.refresh()}
        peerSummary(c)
        mutable.value = mutable.value.copy(reply = JSONObject().put("kind", "peer-v2-invite").put("personal",personal).put("library", result.getString("library")).put("founderKey", result.getString("publicKey")).put("device", c.getString("device")).put("transportKey", crypto(c).publicKey()).put("group", c.getString("group")).put("endpoint", c.getString("endpoint")).toString())
    }
    fun preparePeerJoin(text:String,confirmPersonal:Boolean=false)=action { c ->
        val invitation=JSONObject(text)
        require(invitation.opt("personal") is Boolean)
        val personal=invitation.getBoolean("personal")
        require((!personal||confirmPersonal)&&!c.has("peerExpectedLibrary")&&invitation.getString("kind")=="peer-v2-invite"&&invitation.getString("group")==c.getString("group")&&invitation.getString("endpoint")==c.getString("endpoint"))
        val result=vault.command("relay-peer-identity",JSONObject().put("device",c.getString("device")).put("personal",personal).put("confirmPersonalSync",confirmPersonal).put("migrateLegacy",true))
        c.put("peerPreviousLibrary",c.optString("peerLibrary")).put("peerPreviousPeers",JSONObject(c.getJSONObject("peers").toString())).put("peerPreviousPaused",c.optBoolean("paused",true))
        c.put("peerLibrary",result.getString("library")).put("peerPendingLocalLibrary",result.getString("library")).put("peerExpectedLibrary",invitation.getString("library")).put("peerFounderKey",invitation.getString("founderKey")).put("paused",false)
        c.getJSONObject("peers").put(invitation.getString("device"),invitation.getString("transportKey"))
        mutable.value=mutable.value.copy(reply=JSONObject().put("kind","peer-v2-request").put("personal",personal).put("library",invitation.getString("library")).put("device",c.getString("device")).put("publicKey",result.getString("publicKey")).put("transportKey",crypto(c).publicKey()).put("group",c.getString("group")).toString())
    }
    fun cancelPeerJoin()=action { c ->
        require(c.has("peerExpectedLibrary"))
        vault.command("relay-peer-cancel-join",JSONObject().put("library",c.optString("peerPendingLocalLibrary",c.getString("peerLibrary"))))
        val previous=c.optString("peerPreviousLibrary");if(previous.isEmpty())c.remove("peerLibrary")else c.put("peerLibrary",previous)
        c.put("peers",c.optJSONObject("peerPreviousPeers")?:JSONObject()).put("paused",c.optBoolean("peerPreviousPaused",true))
        listOf("peerPendingLocalLibrary","peerExpectedLibrary","peerFounderKey","peerPreviousLibrary","peerPreviousPeers","peerPreviousPaused").forEach(c::remove)
        mutable.value=mutable.value.copy(reply="")
    }
    fun authorizePeerRequest(text: String, role: String = "editor") = action { c ->
        val request = JSONObject(text)
        require(role in setOf("admin", "editor", "reader") && request.getString("kind") == "peer-v2-request" && request.getString("library") == c.getString("peerLibrary") && request.getString("group") == c.getString("group"))
        vault.command("relay-peer-authorize", JSONObject().put("library", c.getString("peerLibrary")).put("peer", request.getString("device")).put("member", JSONObject().put("publicKey", request.getString("publicKey")).put("transportKey", request.getString("transportKey")).put("role", role)))
        peerSummary(c)
    }
    fun rekeyPeerLibrary()=action { c ->
        require(c.optString("group").isNotEmpty())
        val result=vault.command("relay-peer-rekey",JSONObject().put("library",c.getString("peerLibrary")).put("device",c.getString("device")).put("transportKey",crypto(c).publicKey()))
        c.put("peerLibrary",result.getString("library"))
        mutable.value=mutable.value.copy(reply=JSONObject().put("kind","peer-v2-invite").put("personal",result.optBoolean("personal",false)).put("library",result.getString("library")).put("founderKey",result.getString("publicKey")).put("device",c.getString("device")).put("transportKey",crypto(c).publicKey()).put("group",c.getString("group")).put("endpoint",c.getString("endpoint")).toString())
        peerSummary(c);vault.refresh()
    }
    fun resolvePeer(key: String, value: Any) = action { c ->
        vault.command("relay-peer-resolve", JSONObject().put("library", c.getString("peerLibrary")).put("key", key).put("value", value)); vault.refresh()
    }
    fun revokePeer(peer: String) = action { c ->
        vault.command("relay-peer-authorize", JSONObject().put("library", c.getString("peerLibrary")).put("peer", peer).put("member", JSONObject.NULL)); peerSummary(c)
    }
    fun importCredential(text: String, endpoint: String) = action { c ->
        require(!c.has("groups"))
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
        require(!c.has("peerLibrary"))
        val invitation = JSONObject(text)
        require(c.getString("token").isNotEmpty() && invitation.getInt("version") == 1 && invitation.getString("group") == c.getString("group") && invitation.getString("endpoint") == c.getString("endpoint"))
        val expiry = invitation.getLong("expires"); val now = System.currentTimeMillis()/1000
        require(expiry > now && expiry <= now + 310)
        val hub = invitation.getString("hub"); val public = invitation.getString("key"); val nonce = invitation.getString("nonce")
        require(Crypto.unhex(public).size == 32)
        if (c.optJSONObject("groups")?.has("group_entry") == true) {
            val g = groups(c); val result = g.refresh(); applyGroup(c, g, result.getJSONArray("online"))
            require(g.config.getJSONObject("trusted_peers").optString(hub) == public)
        }
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
        c.put("access_enabled", false)
        vault.command("relay-revoke", JSONObject().put("peer", hub)); c.put("peers", JSONObject()).put("paused", true)
        mutable.value = mutable.value.copy(reply = "", code = "")
    }
    fun setUnlocked(value: Boolean) {
        if (value == unlocked) return
        unlocked = value
        if (!value) {
            epoch++; client?.close(); loop?.cancel()
            config = null
            mutable.value = RelayUi(status = "已锁定 / Locked")
        } else scope.launch { actions.withLock { stop(); loadCredentials(); start() } }
    }
    suspend fun close() { unlocked = false; stop(); scope.cancel(); http.connectionPool.evictAll() }
    fun syncNow() { wake = true; scope.launch { actions.withLock { if (loop?.isActive != true) start() } } }
    private suspend fun stop() {
        epoch++; client?.close(); loop?.cancelAndJoin(); loop = null
        mutable.value = mutable.value.copy(members = mutable.value.members.map { it.copy(online = false) },
            status = if (unlocked) "未连接 / Disconnected" else "已锁定 / Locked")
    }
    private fun start() {
        val c = config ?: return
        val managed = c.optJSONObject("groups")?.has("group_entry") == true
        if (!unlocked || c.optJSONObject("groups")?.optBoolean("access_invalid") == true || c.optString("token").isEmpty() ||
            (!managed && (c.optBoolean("paused", true) || c.getJSONObject("peers").length() == 0))) return
        val snapshot = JSONObject(c.toString()); val generation = epoch
        loop = scope.launch { run(snapshot, generation) }
    }
    private suspend fun run(c: JSONObject, generation: Int) {
        var backoff = 1000L
        while (currentCoroutineContext().isActive && unlocked && generation == epoch) {
            var connection: RelayClient? = null
            try {
                refreshGroupForConnection(c, generation)
                currentCoroutineContext().ensureActive()
                if (journal == null) journal = RelayJournal(File(storage, "journal").toPath())
                val crypto = crypto(c)
                val connectionPeerKeys = c.getJSONObject("peers").toString()
                val events = Channel<JSONObject>(64); val ready = CompletableDeferred<Unit>()
                connection = RelayClient(http, crypto, object: RelayClient.Listener {
                    override fun onReady() { ready.complete(Unit) }
                    override fun onEvent(event: JSONObject) { if (events.trySend(event).isFailure) events.close(IllegalStateException("Event backlog")) }
                    override fun onClosed(error: Throwable) { ready.completeExceptionally(error); events.close(error) }
                }, journal)
                client = connection
                mutable.value = mutable.value.copy(status = "正在连接 / Connecting")
                connection.connect(c.getString("endpoint"), c.getString("token"), c.optString("password").ifEmpty { null })
                withTimeout(45_000) { ready.await() }
                val canSync = !c.optBoolean("paused", true) && c.getJSONObject("peers").length() > 0
                val connected = if (c.getJSONObject("peers").length() == 0) "中继已连接，密码库尚未授权 / Relay connected; vault not authorized"
                    else if (!canSync) "中继已连接，密码库同步已暂停 / Relay connected; vault sync paused" else "已连接 / Connected"
                mutable.value = mutable.value.copy(status = connected,
                    error = mutable.value.error.takeUnless { it == transportFailure })
                transportFailure = null; backoff = 1000
                val fileClient = RelayFiles(http, c.getString("endpoint").replaceFirst("wss://", "https://").removeSuffix("/ws") + "/files", c.getString("token"), c.optString("password").ifEmpty { null })
                val peerSent = mutableMapOf<String, String>()
                while (currentCoroutineContext().isActive && unlocked && generation == epoch) {
                    while (true) {
                        val result = events.tryReceive()
                        if (result.isClosed) throw IllegalStateException("Disconnected")
                        val event = result.getOrNull() ?: break
                        if (event.optString("type") == "message") {
                            val data = Base64.getDecoder().decode(event.getString("data"))
                            val from = event.getString("from")
                            val payload = JSONObject(String(data))
                            if (payload.optString("format") == "passwordvault.capabilities.v1") {
                                receiveCapabilities(c, payload, from, generation)?.let { connection.sendOnline(from, it.toString().toByteArray()) }
                                peerSent.clear()
                            } else if (receiveAuthorization(c, payload, from, generation)) {
                                val reply = JSONObject(String(data)).put("kind", "ack").put("to", from)
                                    .put("capabilitiesFrom", c.getString("device")).put("capabilitiesVersion", 2)
                                // Authorization has already been verified and persisted. This
                                // is a background delivery receipt, never a user approval.
                                // The sender retries the grant if this online receipt is lost.
                                connection.sendOnline(from, reply.toString().toByteArray())
                            } else {
                                if (JSONObject(String(data)).optString("format") == "passwordvault.access.v1") continue
                                if (c.optBoolean("paused", true) || !c.getJSONObject("peers").has(from) || (!c.has("peerLibrary") && from != c.getString("hub"))) continue
                                try { receive(data, from, generation, c) }
                                catch (_: com.securepass.vault.core.VaultException.DevicesSyncBlocked) { continue }
                            }
                            connection.acknowledge(event).get(45, TimeUnit.SECONDS)
                        } else if (event.optString("type") == "group.changed" && event.optInt("revision") >
                            (c.optJSONObject("groups")?.optJSONObject("group_entry")?.let { RelayGroups.unpack(it).optInt("revision") } ?: 0)) throw IllegalStateException("Membership changed")
                        else if (event.optString("type") == "peer.up") peerSent.clear()
                    }
                    if (c.optJSONObject("groups")?.has("group_entry") == true) {
                        val devices = connection.peers().get(45, TimeUnit.SECONDS).getJSONArray("devices")
                        currentCoroutineContext().ensureActive(); check(unlocked && generation == epoch)
                        val online = (0 until devices.length()).map { devices.getJSONObject(it) }
                            .filter { it.optString("app") == "passwordvault" && it.optString("group") == c.getString("group") }
                            .map { it.getString("device") }.toSet() + c.getString("device")
                        mutable.value = mutable.value.copy(members = mutable.value.members.map { it.copy(online = it.id in online) })
                    }
                    for ((peer, control) in capabilityMessages(c)) connection.sendOnline(peer, control.toString().toByteArray())
                    if (!c.optBoolean("paused", true) && c.getJSONObject("peers").length() > 0) {
                        val peerMode = c.has("peerLibrary")
                        val summary = if (peerMode) peerSummary(c) else vault.command("relay-status")
                        if (peerMode && c.optJSONObject("groups") == null && connectionPeerKeys != c.getJSONObject("peers").toString()) throw IllegalStateException("Authorized peer keys changed; reconnect")
                        mutable.value = mutable.value.copy(pending = summary.optInt("pending"), conflicts = if (peerMode) summary.optJSONObject("conflicts")?.length() ?: 0 else summary.optInt("conflictCount"), peerConflicts = summary.optJSONObject("conflicts")?.toString() ?: "{}")
                        val destinations = if (peerMode) c.getJSONObject("peers").keys().asSequence().toList() else listOf(c.getString("hub"))
                        for(peer in destinations) {
                          val libraries=if(peerMode) peerRosters.filterValues {it.has(peer)}.keys.toList() else listOf("")
                          for(library in libraries) {
                            val packet = try { vault.command(if(peerMode) "relay-peer-export" else "relay-export",JSONObject().put("peer",peer).apply {if(peerMode)put("library",library)}).toString().toByteArray() }
                                catch (_: com.securepass.vault.core.VaultException.DevicesSyncBlocked) { continue }
                            val signature = hex(hash(packet)) + ":" + System.currentTimeMillis()/3_600_000 + ":" + c.optLong("access_revision") + ":" + c.optJSONObject("capabilityReady")?.optString(peer).orEmpty()
                            val route=peer+":"+library
                            if (peerSent[route] != signature || wake) {
                                if (packet.size <= 128*1024) connection.message(peer, packet, true, hex(hash((peer + signature).toByteArray())).take(32)).get(45, TimeUnit.SECONDS)
                                else if (peerMode) {
                                    require(packet.size <= 48*1024*1024)
                                    val digest=hex(hash(packet));val count=(packet.size+65535)/65536
                                    for(index in 0 until count) {
                                        val part=packet.copyOfRange(index*65536,minOf(packet.size,(index+1)*65536))
                                        val chunk=JSONObject().put("protocol","peer-v2-chunk").put("library",library).put("transfer",digest.take(32)).put("index",index).put("count",count).put("total",packet.size).put("digest",digest).put("data",Base64.getEncoder().encodeToString(part))
                                        connection.message(peer,chunk.toString().toByteArray(),true,hex(hash((route+signature+":"+index).toByteArray())).take(32)).get(45,TimeUnit.SECONDS)
                                        delay(25)
                                    }
                                } else sendFile(packet, crypto, peer, fileClient)
                                peerSent[route] = signature
                            }
                          }
                        }
                        wake = false
                        val inbox = fileClient.inbox()
                        for (index in 0 until inbox.length()) {
                            val file = inbox.getJSONObject(index); val from = file.getString("from")
                            require(c.getJSONObject("peers").has(from) && (peerMode || from == c.getString("hub")) && file.getLong("size") <= 768L*1024*1024)
                            val cipher = File(storage, UUID.randomUUID().toString()+".download")
                            val inner = File(storage, UUID.randomUUID().toString()+".sealed")
                            try {
                                fileClient.download(file, cipher)
                                val meta = RelayFiles.decrypt(crypto, from, file, cipher, inner)
                                require(meta.getString("format") == "passwordvault.sync.v1")
                                receive(decrypt(inner.readBytes(), SecretKeySpec(Crypto.unhex(meta.getString("key")), "AES")), from, generation, c)
                                fileClient.acknowledge(file.getString("id"))
                            } catch (_: com.securepass.vault.core.VaultException.DevicesSyncBlocked) {
                                // Leave the encrypted file pending until capability negotiation completes.
                            } finally { cipher.delete(); inner.delete() }
                        }
                    }
                    delay(5000)
                }
            } catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) {
                if (unlocked && generation == epoch) {
                    transportFailure = "同步未完成，本地改动已保留 / Sync incomplete; local changes retained"
                    mutable.value = mutable.value.copy(status = "等待重连 / Waiting to reconnect", error = mutable.value.error ?: transportFailure)
                }
            }
            finally {
                connection?.close()
                if (generation == epoch) mutable.value = mutable.value.copy(members = mutable.value.members.map { it.copy(online = false) })
            }
            if (mutable.value.invalid) return
            delay(backoff); backoff = (backoff*2).coerceAtMost(30_000)
        }
    }
    private suspend fun receive(data: ByteArray, hub: String, generation: Int, c: JSONObject) {
        check(unlocked && generation == epoch)
        if (c.has("peerLibrary")) {
            val incomingEnvelope=JSONObject(String(data));val incomingLibrary=incomingEnvelope.optJSONObject("packet")?.getString("library") ?: incomingEnvelope.getString("library")
            if (c.has("peerExpectedLibrary") && incomingLibrary==c.getString("peerExpectedLibrary")) {
                val result = vault.command("relay-peer-join", JSONObject().put("library", c.optString("peerPendingLocalLibrary",c.getString("peerLibrary"))).put("expectedLibrary", c.getString("peerExpectedLibrary")).put("founderKey", c.getString("peerFounderKey")).put("envelope", JSONObject(String(data))).put("sender",hub))
                if(result.optBoolean("partial"))return
                c.put("peerLibrary", result.getString("library")); listOf("peerPendingLocalLibrary","peerExpectedLibrary","peerFounderKey","peerPreviousLibrary","peerPreviousPeers","peerPreviousPaused").forEach(c::remove); config = c; save(c)
            } else {
                val registered=vault.command("relay-peer-list").getJSONArray("libraries")
                if((0 until registered.length()).none {registered.getJSONObject(it).getString("id")==incomingLibrary})return
                val current = vault.command("relay-peer-status", JSONObject().put("library", incomingLibrary))
                if(current.optBoolean("frozen"))return
                require(current.getJSONObject("members").getJSONObject(hub).getString("transportKey") == c.getJSONObject("peers").getString(hub))
                val result=vault.command("relay-peer-receive", JSONObject().put("library", incomingLibrary).put("envelope", JSONObject(String(data))).put("sender",hub))
                if(result.optBoolean("partial"))return
            }
        } else vault.command("relay-receive", JSONObject().put("peer", hub).put("packet", JSONObject(String(data))))
        check(unlocked && generation == epoch)
        vault.refresh()
        val summary = if (c.has("peerLibrary")) peerSummary(c) else vault.command("relay-status")
        mutable.value = mutable.value.copy(lastReceived = System.currentTimeMillis(), pending = summary.optInt("pending"), conflicts = summary.optInt("conflictCount"))
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
    private fun groups(c: JSONObject): RelayGroups {
        check(c.has("groups") || c.optString("token").isEmpty()) { "Legacy access requires explicit reset" }
        val g = c.optJSONObject("groups") ?: JSONObject().put("app", "passwordvault")
            .put("device", c.getString("device")).put("secret_key", c.getString("secret"))
            .put("url", "wss://relay.example.test/relay/v1/ws")
        pinVaultAuthority(c, g)
        return RelayGroups(g, false, http)
    }
    private suspend fun saveGroup(c: JSONObject, g: RelayGroups) { pinVaultAuthority(c, g.config); c.put("groups", g.config); save(c) }
    private suspend fun applyGroup(c: JSONObject, g: RelayGroups, online: org.json.JSONArray = org.json.JSONArray()) {
        saveGroup(c, g)
        check(unlocked)
        val entry = g.config.optJSONObject("group_entry") ?: return
        val group = RelayGroups.unpack(entry); val members = group.getJSONArray("members")
        if (group.optBoolean("closed") || (0 until members.length()).none { members.getJSONObject(it).getString("device") == c.getString("device") }) {
            invalidateGroup(c); error("Group access revoked")
        }
        c.put("endpoint", g.config.getString("url")).put("group", g.config.getString("group")).put("token", g.config.getString("token"))
        if (g.config.has("password")) c.put("password", g.config.getString("password"))
        val trusted = g.config.getJSONObject("trusted_peers"); val peers = c.getJSONObject("peers")
        for (id in peers.keys().asSequence().toList()) if (trusted.optString(id) != peers.getString(id)) {
            if (!c.has("peerLibrary")) vault.command("relay-revoke", JSONObject().put("peer", id)); peers.remove(id)
        }
        save(c)
        mutable.value = mutable.value.copy(groupFresh = true, groupName = group.optString("name", c.getString("group")),
            members = (0 until members.length()).map { index ->
                val m = members.getJSONObject(index); val id = m.getString("device")
                RelayMember(id, m.getString("name"), m.getBoolean("manager"), (0 until online.length()).any { online.optString(it) == id })
            })
    }
    private suspend fun invalidateGroup(c: JSONObject) {
        c.put("paused", true); c.getJSONObject("groups").put("access_invalid", true); save(c)
        mutable.value = mutable.value.copy(groupFresh = false, members = emptyList(), invalid = true)
    }
    private fun groupAction(block: suspend (JSONObject, RelayGroups) -> Unit) { scope.launch {
        actions.withLock {
            if (!unlocked) return@withLock
            mutable.value = mutable.value.copy(busy = true, error = null)
            stop()
            try {
                val c = checkNotNull(config); val g = groups(c)
                try { block(c, g) } catch (error: Exception) { saveGroup(c, g); throw error }
                publish()
            } catch (cancel: CancellationException) { throw cancel }
            catch (error: Exception) {
                publish()
                mutable.value = mutable.value.copy(groupFresh = false, members = emptyList(),
                    error = if (mutable.value.invalid) "接入已失效，请确认清除本机接入后重新加入 / Access invalid; clear local access to rejoin"
                    else relayFailure(error))
            } finally { mutable.value = mutable.value.copy(busy = false); start() }
        }
    } }
    fun createGroup(endpoint: String, name: String, deviceName: String, password: String) = groupAction { c, g ->
        check(!g.config.has("group_entry") && !g.config.has("pending_join") && c.optString("token").isEmpty())
        require(name.isNotBlank() && deviceName.isNotBlank())
        val url = validateRelayEndpoint(endpoint)
        validateRelayPassword(password)
        if (!g.config.has("pending_create")) g.config.put("url", url)
        else require(g.config.getString("url") == url)
        g.config.put("password", password)
        // Constructor validates the configured endpoint before any request.
        val sdk = RelayGroups(g.config, false, http)
        sdk.prepareCreate(name, deviceName); saveGroup(c, sdk); sdk.create(); applyGroup(c, sdk)
        mutable.value = mutable.value.copy(status = "设备组已创建，等待密码库授权 / Group created; authorize vault sync")
    }
    fun joinGroup(text: String, deviceName: String, password: String) = groupAction { c, g ->
        check(!g.config.has("group_entry") && !g.config.has("pending_create") && c.optString("token").isEmpty())
        require(text.toByteArray().size <= 16384)
        validateRelayPassword(password)
        require(deviceName.isNotBlank())
        val preview = RelayInvitationPreview.read(text)
        val input = preview.input
        val inv = if (input.startsWith("common-relay:")) g.resolveInvitation(input, password) else JSONObject(input)
        require(inv.getString("url") == preview.endpoint)
        inv.put("password", password)
        require(inv.getString("app") == "passwordvault")
        g.config.optJSONObject("pending_join")?.let { require(it.getJSONObject("invitation").toString() == inv.toString()) }
        g.config.put("url", inv.getString("url")).put("group", inv.getString("group")).put("password", password)
        val sdk = RelayGroups(g.config, false, http)
        sdk.prepareJoin(inv, deviceName); saveGroup(c, sdk); sdk.join(inv, deviceName); saveGroup(c, sdk)
        if (inv.optString("mode") == "auto") {
            check(sdk.finishJoin()); applyGroup(c, sdk)
            mutable.value = mutable.value.copy(status = "已入组，密码库同步尚未授权 / Joined; vault sync needs authorization")
        } else mutable.value = mutable.value.copy(status = "请核对两端配对码 / Compare codes on both devices")
    }
    // Updating server access never resets device identity, pinned keys, or vault authorization.
    fun updateServerPassword(password: String) = action { c ->
        updateRelayAccessCredential(c, password)
        save(c)
        val stored = c.optJSONObject("groups")
        if (stored?.has("group_entry") == true) {
            // Old clients treated all HTTP 401s as revocation. Recover only after a verified refresh.
            val sdk = groups(c)
            val result = sdk.refresh()
            applyGroup(c, sdk, result.getJSONArray("online"))
            sdk.config.remove("access_invalid")
            saveGroup(c, sdk)
        }
        mutable.value = mutable.value.copy(status = "服务器密码已保存，请重试 / Server password saved; retry")
    }
    private fun relayFailure(error: Exception): String = when {
        error.message.orEmpty().contains("(401)") -> "服务器密码错误、缺失或设备凭据被拒绝；原身份已保留，请修改密码后重试 / Access rejected; identity retained. Update server password and retry"
        error.message.orEmpty().contains("(404)") || error.message.orEmpty().contains("(410)") || error.message.orEmpty().contains("expired", true) -> "邀请已失效或不存在，请获取新邀请；输入已保留 / Invitation expired or unavailable; inputs retained"
        else -> "操作未完成，请检查网络、邀请与服务权限；输入和身份已保留 / Operation incomplete; check network and invitation. Inputs and identity retained"
    }
    fun retryGroupJoin() = groupAction { c, g ->
        val pending = g.config.getJSONObject("pending_join")
        val name = RelayGroups.unpack(pending.getJSONObject("request")).getJSONObject("member").getString("name")
        g.join(pending.getJSONObject("invitation"), name); saveGroup(c, g)
        if (pending.getJSONObject("invitation").optString("mode") == "auto" && g.finishJoin()) applyGroup(c, g)
    }
    fun finishGroupJoin() = groupAction { c, g ->
        if (g.finishJoin()) {
            applyGroup(c, g)
            mutable.value = mutable.value.copy(status = "已入组，密码库同步尚未授权 / Joined; vault sync needs authorization")
        } else mutable.value = mutable.value.copy(status = "等待邀请方批准 / Waiting for approval")
    }
    fun refreshGroup() = groupAction { c, g -> val result = g.refresh(); applyGroup(c, g, result.getJSONArray("online")) }
    fun inviteToGroup(automatic: Boolean = true) = groupAction { c, g ->
        val old = g.config.optJSONObject("issued_invitation")
        if (old == null || old.optLong("expires") <= System.currentTimeMillis()/1000) {
            val inv = g.invite(if (automatic) "auto" else "manual")
            g.config.put("issued_invitation", inv); saveGroup(c, g)
            g.publishInvitation(inv); g.config.remove("join_request")
        } else if (!old.has("short_link")) { g.publishInvitation(old) }
        applyGroup(c, g)
    }
    fun checkGroupRequest() = groupAction { c, g ->
        require(g.config.getJSONObject("issued_invitation").optString("mode") != "auto")
        g.config.put("join_request", g.pending(g.config.getJSONObject("issued_invitation")))
        val result = g.refresh(); applyGroup(c, g, result.getJSONArray("online"))
        if (!g.config.has("join_request")) mutable.value = mutable.value.copy(status = "尚无加入申请 / No request yet")
    }
    fun approveGroupRequest(manager: Boolean) = groupAction { c, g ->
        g.approve(g.config.getJSONObject("issued_invitation"), g.config.getJSONObject("join_request"), manager)
        g.config.remove("issued_invitation"); g.config.remove("join_request"); applyGroup(c, g)
    }
    fun cancelGroupInvitation() = groupAction { c, g ->
        g.cancel(g.config.getJSONObject("issued_invitation")); g.config.remove("issued_invitation"); g.config.remove("join_request"); applyGroup(c, g)
    }
    fun renameGroupMember(device: String, name: String) = groupAction { c, g -> g.rename(device, name); applyGroup(c, g) }
    fun removeGroupMember(device: String) = groupAction { c, g -> g.remove(device); applyGroup(c, g) }
    fun leaveGroup(disband: Boolean) = groupAction { c, g ->
        if (g.config.has("pending_exit") || g.config.optBoolean("exit_completed")) require(g.config.getBoolean("exit_disband") == disband)
        g.config.put("exit_disband", disband)
        if (!g.config.optBoolean("exit_completed")) {
            g.prepareExit(disband); saveGroup(c, g); g.exit(); g.config.put("exit_completed", true); saveGroup(c, g)
        }
        clearGroupAccess(c)
    }
    fun clearLocalGroup() = action { c -> check(unlocked); clearGroupAccess(c) }
    private suspend fun clearGroupAccess(c: JSONObject) {
        val old = vault.command("relay-status")
        if (old.optBoolean("enabled")) vault.command("relay-detach", JSONObject().put("group", old.getString("group")).put("device", old.getString("device")))
        val previous = JSONObject(c.toString())
        c.remove("access_revision"); c.remove("access_enabled")
        c.remove("groups"); c.remove("password"); c.put("group", "").put("token", "").put("hub", "").put("peers", JSONObject())
            .put("paused", true).put("device", UUID.randomUUID().toString())
        try { save(c) } catch (error: Exception) {
            c.keys().asSequence().toList().forEach { c.remove(it) }
            previous.keys().forEach { c.put(it, previous.get(it)) }
            throw error
        }
        mutable.value = mutable.value.copy(groupFresh = false, members = emptyList(), groupName = "", reply = "", code = "", pending = 0,
            status = "本机接入已清除，本地资料保留 / Local access cleared; vault retained")
    }
    private suspend fun refreshGroupForConnection(snapshot: JSONObject, generation: Int) {
        actions.withLock {
            currentCoroutineContext().ensureActive(); check(unlocked && generation == epoch)
            val c = checkNotNull(config)
            if (c.optJSONObject("groups")?.has("group_entry") != true) return@withLock
            check(!c.getJSONObject("groups").optBoolean("access_invalid"))
            mutable.value = mutable.value.copy(busy = true)
            try {
                val g = groups(c); val result = g.refresh()
                currentCoroutineContext().ensureActive(); check(unlocked && generation == epoch)
                applyGroup(c, g, result.getJSONArray("online")); publish()
                snapshot.keys().asSequence().toList().forEach { snapshot.remove(it) }
                val fresh = JSONObject(c.toString())
                fresh.keys().forEach { snapshot.put(it, fresh.get(it)) }
            } catch (error: Exception) {
                mutable.value = mutable.value.copy(groupFresh = false, members = emptyList())
                throw error
            } finally { mutable.value = mutable.value.copy(busy = false) }
        }
    }

    private fun pinVaultAuthority(c: JSONObject, g: JSONObject) {
        if (g.has("vault_authority")) return
        val entry = g.optJSONObject("group_entry") ?: return
        val members = RelayGroups.unpack(entry).getJSONArray("members")
        val managers = (0 until members.length()).map { members.getJSONObject(it) }.filter { it.optBoolean("manager") }
        if (managers.size == 1 && managers[0].getString("device") != c.getString("device")) g.put("vault_authority", managers[0])
    }
    // Only the authority pinned from the verified enrollment may offer access.
    // Ordinary group membership never permits a peer to request vault contents.
    internal suspend fun receiveAuthorization(c: JSONObject, p: JSONObject, from: String, generation: Int): Boolean {
        if (c.has("peerLibrary")) return false
        if (p.optString("format") != "passwordvault.access.v1") return false
        val g = c.optJSONObject("groups") ?: return false
        val authority = g.optJSONObject("vault_authority") ?: return false
        val key = g.optJSONObject("trusted_peers")?.optString(from).orEmpty()
        if (!unlocked || generation != epoch || g.optBoolean("access_invalid") || key.isEmpty() ||
            p.optString("kind") != "set" || p.optString("group") != c.getString("group") ||
            p.optString("to") != c.getString("device") || p.optString("permission") != "read-write" ||
            authority.optString("device") != from || authority.optString("public_key") != key ||
            (c.optString("hub").isNotEmpty() && c.getString("hub") != from)) return false
        val revision = p.optLong("revision")
        if (revision <= 0 || revision < c.optLong("access_revision") || p.opt("enabled") !is Boolean) return false
        val enabled = p.getBoolean("enabled")
        if (revision == c.optLong("access_revision")) {
            if (enabled != c.optBoolean("access_enabled")) return false
            rememberCapabilities(c, p, from, key)
            save(c); config = JSONObject(c.toString())
            return true
        }
        val previous = JSONObject(c.toString())
        val current = vault.command("relay-status")
        if (current.optBoolean("enabled")) require(current.getString("hub") == from && current.getString("group") == c.getString("group"))
        else vault.command("relay-init", JSONObject().put("role", "mobile").put("device", c.getString("device")).put("group", c.getString("group")).put("hub", from))
        check(unlocked && generation == epoch)
        val peers = c.getJSONObject("peers")
        if (enabled) {
            vault.command("relay-trust", JSONObject().put("peer", from))
            peers.put(from, key); c.put("paused", false)
        } else {
            peers.remove(from)
            vault.command("relay-revoke", JSONObject().put("peer", from))
        }
        c.put("hub", from).put("access_revision", revision).put("access_enabled", enabled)
        c.optJSONObject("capabilityReady")?.remove(from)
        rememberCapabilities(c, p, from, key)
        try { save(c) } catch (error: Exception) {
            c.keys().asSequence().toList().forEach { c.remove(it) }
            previous.keys().forEach { c.put(it, previous.get(it)) }
            throw error
        }
        check(unlocked && generation == epoch)
        config = JSONObject(c.toString()); publish()
        mutable.value = mutable.value.copy(status = if (enabled) "已授权查看并同步修改 / Authorized to view and sync changes" else "密码库授权已关闭 / Vault access revoked")
        return true
    }

    private fun rememberCapabilities(c: JSONObject, p: JSONObject, from: String, key: String) {
        if (p.optString("capabilitiesFrom") != from || p.optInt("capabilitiesVersion") != 2) return
        val peers = c.optJSONObject("capabilityPeers") ?: JSONObject().also { c.put("capabilityPeers", it) }
        peers.put(from, key)
    }
    private suspend fun capabilityMessages(c: JSONObject): List<Pair<String, JSONObject>> {
        if (c.has("peerLibrary") || c.getJSONObject("peers").length() == 0) return emptyList()
        val state = vault.command("relay-status")
        if (!state.optBoolean("enabled")) return emptyList()
        val verified = state.optJSONArray("capabilities")
        val trusted = c.optJSONObject("groups")?.optJSONObject("trusted_peers") ?: return emptyList()
        return c.getJSONObject("peers").keys().asSequence().mapNotNull { peer ->
            val key = c.getJSONObject("peers").getString(peer)
            // Upgraded peers may retain grants made before capability advertisements.
            // Discovery is automatic; core still requires an authenticated proof.
            if (trusted.optString(peer) != key) null
            else peer to JSONObject().put("format", "passwordvault.capabilities.v1").put("group", c.getString("group")).put("to", peer)
                .put("kind", if (verified != null && (0 until verified.length()).any { verified.optString(it) == peer }) "ready" else "challenge")
        }.toList().map { (peer, p) ->
            if (p.getString("kind") == "challenge") p.put("challenge", vault.command("relay-capabilities-challenge", JSONObject().put("peer", peer)).getString("challenge"))
            peer to p
        }
    }
    internal suspend fun receiveCapabilities(c: JSONObject, p: JSONObject, from: String, generation: Int): JSONObject? {
        check(unlocked && generation == epoch)
        val g = c.optJSONObject("groups") ?: return null
        val key = g.optJSONObject("trusted_peers")?.optString(from).orEmpty()
        if (c.has("peerLibrary") || g.optBoolean("access_invalid") || key.isEmpty() || c.getJSONObject("peers").optString(from) != key ||
            p.optString("format") != "passwordvault.capabilities.v1" || p.optString("group") != c.getString("group") || p.optString("to") != c.getString("device")) return null
        fun reply(kind: String) = JSONObject().put("format", "passwordvault.capabilities.v1").put("kind", kind).put("group", c.getString("group")).put("to", from)
        return when (p.optString("kind")) {
            "challenge" -> reply("proof").put("proof", vault.command("relay-capabilities-prove", JSONObject().put("peer", from).put("challenge", p.getString("challenge"))).getJSONObject("proof"))
            "proof" -> {
                try { vault.command("relay-capabilities-accept", JSONObject().put("peer", from).put("proof", p.getJSONObject("proof"))) }
                catch (_: com.securepass.vault.core.VaultException.Authentication) { return null }
                reply("ready")
            }
            "ready" -> {
                val ready = c.optJSONObject("capabilityReady") ?: JSONObject().also { c.put("capabilityReady", it) }
                if (ready.optString(from) != key) {
                    ready.put(from, key); save(c)
                    check(unlocked && generation == epoch); config = JSONObject(c.toString())
                }
                null
            }
            else -> null
        }
    }

    companion object {
        private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        private fun hex(bytes: ByteArray) = Crypto.hex(bytes)
        private fun encrypt(bytes: ByteArray, key: SecretKey): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.ENCRYPT_MODE, key); iv + doFinal(bytes) }
        private fun decrypt(bytes: ByteArray, key: SecretKey): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run { require(bytes.size >= 28); init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0,12))); doFinal(bytes.copyOfRange(12,bytes.size)) }
    }
}
