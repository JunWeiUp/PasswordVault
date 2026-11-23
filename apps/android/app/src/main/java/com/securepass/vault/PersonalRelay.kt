package com.securepass.vault

import com.securepass.vault.core.RelayConnection
import com.securepass.vault.core.RelayFileClient
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
import org.json.JSONObject

internal data class RelayMember(val id: String, val name: String, val manager: Boolean, val online: Boolean)

internal data class RelayUi(
    val peerLibrary: String = "", val peerConflicts: String = "{}", val peerLibraries: String = "[]", val activePeerLibrary: String = "", val peerRole: String = "blocked", val peerFrozen: Boolean = false, val peerPending: Boolean = false, val peerDevice: String = "",
    val credentialsBlocked: Boolean = false, val automaticJoin: Boolean = false, val managed: Boolean = false, val legacy: Boolean = false, val joining: Boolean = false, val creating: Boolean = false,
    val draftGroupName: String = "", val draftDeviceName: String = "",
    val invalid: Boolean = false, val busy: Boolean = false, val groupFresh: Boolean = false, val groupName: String = "",
    val members: List<RelayMember> = emptyList(), val groupInvite: String = "", val groupInviteExpires: Long = 0L, val groupCode: String = "", val applicant: String = "",
    val status: String = "未连接 / Disconnected", val error: String? = null,
    val publicKey: String = "", val device: String = "", val group: String = "", val endpoint: String = "",
    val paired: Boolean = false, val paused: Boolean = true, val pending: Int = 0, val conflicts: Int = 0,
    val reply: String = "", val code: String = "", val lastReceived: Long? = null,
    val sync: RelaySyncProgress = RelaySyncProgress(),
    /** Symmetric sync: every member of the signed group syncs; no grant or primary confirmation. */
    val mesh: Boolean = false,
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
    @Volatile private var client: RelayConnection? = null
    @Volatile private var unlocked = false
    @Volatile private var epoch = 0
    @Volatile private var wake = false
    private val syncRequests = Channel<Unit>(Channel.CONFLATED)
    private fun progress(generation: Int, phase: RelaySyncPhase, completed: Int = 0, total: Int = 0) {
        if (unlocked && generation == epoch) mutable.value = mutable.value.copy(
            sync = mutable.value.sync.copy(phase = phase, completed = completed, total = total))
    }
    @Volatile private var transportFailure: String? = null

    private fun legacyKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        return ks.getKey(alias, null) as? SecretKey ?: error("Legacy relay key unavailable")
    }
    private suspend fun loadCredentials() {
        if (!unlocked) return
        val generation = epoch
        mutable.value = mutable.value.copy(busy = true, error = null)
        try {
            val stored = vault.command(CoreRequest.relayCredentialsRead())
            check(unlocked && generation == epoch)
            val migrating = stored.isNull("data")
            val legacyExists = migrating && configFile.exists()
            val loaded = if (!migrating) JSONObject(stored.getString("data"))
            else if (configFile.exists()) JSONObject(String(decrypt(configFile.readBytes(), legacyKey())))
            else JSONObject().put("device", UUID.randomUUID().toString()).put("secret", RelayCore.hex(RelayCore.random(32)))
                .put("group", "").put("hub", "").put("endpoint", "").put("token", "").put("paused", true)
                .put("peers", JSONObject())
            publicKey(loaded) // Validate legacy identity before committing migration.
            if (migrating) {
                val encoded = loaded.toString()
                vault.command(CoreRequest.relayCredentialsWrite(encoded))
                check(vault.command(CoreRequest.relayCredentialsRead()).getString("data") == encoded)
            }
            check(unlocked && generation == epoch)
            config = loaded
            if (legacyExists && configFile.delete()) {
                runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) } }
            }
            mutable.value = mutable.value.copy(credentialsBlocked = false)
            publish()
            val summary = vault.command(CoreRequest.relayStatus())
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
        vault.command(CoreRequest.relayCredentialsWrite(value.toString()))
    }
    private fun trustedPeers(value: JSONObject): Map<String, String> {
        val peers = value.optJSONObject("groups")?.optJSONObject("trusted_peers") ?: value.getJSONObject("peers")
        return peers.keys().asSequence().associateWith { peers.getString(it) }
    }
    private fun publicKey(value: JSONObject): String = RelayCore.publicKey(value.getString("secret"))
    /** Connection/file options for the current relay credentials (vault-core transport). */
    private fun relayOptions(c: JSONObject, journal: Boolean): String = RelayCore.options(
        c.getString("endpoint"), c.getString("token"), c.optString("password").ifEmpty { null }, c.getString("group"),
        c.getString("device"), c.getString("secret"), trustedPeers(c), if (journal) File(storage, "journal") else null, RelayLocalTest.active)
    private fun publish() {
        val c = config ?: return
        val g = c.optJSONObject("groups")
        val request = g?.optJSONObject("pending_join")?.optJSONObject("request") ?: g?.optJSONObject("join_request")
        val code = request?.let { RelayCore.digest(java.util.Base64.getDecoder().decode(it.getString("payload"))).take(12).uppercase().chunked(4).joinToString("-") }.orEmpty()
        val inv = g?.optJSONObject("issued_invitation")
        val creation = g?.optJSONObject("pending_create")?.let { RelayCore.unpack(it) }
        mutable.value = mutable.value.copy(managed = g?.has("group_entry") == true, legacy = g == null && c.optString("token").isNotEmpty(),
            automaticJoin = (g?.optJSONObject("pending_join")?.optJSONObject("invitation") ?: inv)?.optString("mode") == "auto",
            draftGroupName = creation?.optString("name").orEmpty(), draftDeviceName = creation?.optJSONArray("members")?.optJSONObject(0)?.optString("name").orEmpty(),
            joining = g?.has("pending_join") == true, creating = g?.has("pending_create") == true, invalid = g?.optBoolean("access_invalid") == true,
            groupInvite = if (mutable.value.groupFresh && inv != null && inv.optLong("expires") > System.currentTimeMillis()/1000) inv.optString("short_link").ifEmpty { inv.toString() } else "",
            groupInviteExpires = if (mutable.value.groupFresh && inv != null && inv.optLong("expires") > System.currentTimeMillis()/1000) inv.optLong("expires") else 0L,
            groupCode = code, applicant = if (mutable.value.groupFresh) g?.optJSONObject("join_request")?.let { RelayCore.unpack(it).getJSONObject("member").getString("name") }.orEmpty() else "")
        mutable.value = mutable.value.copy(peerLibrary = c.optString("peerLibrary"), peerPending = c.has("peerExpectedLibrary"), publicKey = publicKey(c), device = c.getString("device"),
            group = c.getString("group"), endpoint = if (creation != null) g.getString("url") else c.getString("endpoint"))
        val mesh = runCatching { meshRoster(c) != null }.getOrDefault(false)
        mutable.value = mutable.value.copy(mesh = mesh, paired = mesh || c.getJSONObject("peers").length() > 0,
            paused = if (mesh) false else c.getBoolean("paused"))
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
        val state = vault.command(CoreRequest.relayPeerStatus(c.getString("peerLibrary")))
        val listing = vault.command(CoreRequest.relayPeerList()); val libraries = listing.getJSONArray("libraries")
        val own=state.optJSONObject("members")?.optJSONObject(state.optString("device"))
        mutable.value=mutable.value.copy(peerRole=if(own?.optString("publicKey")==state.optString("publicKey")) own.optString("role","blocked") else "blocked",peerFrozen=state.optBoolean("frozen"),peerDevice=state.optString("device"),peerPending=c.has("peerExpectedLibrary"))
        mutable.value = mutable.value.copy(peerLibrary=c.optString("peerLibrary"),peerLibraries=libraries.toString(),activePeerLibrary=listing.optString("active").takeUnless { it == "null" }.orEmpty())
        val peers = if (c.has("peerExpectedLibrary")) JSONObject(c.getJSONObject("peers").toString()) else JSONObject()
        val transportRoster = c.optJSONObject("groups")?.optJSONObject("trusted_peers")
        peerRosters.clear()
        for (index in 0 until libraries.length()) {
            val id=libraries.getJSONObject(index).getString("id")
            if (id.startsWith("pending-")) continue
            val details=vault.command(CoreRequest.relayPeerStatus(id))
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
        vault.command(CoreRequest.relayPeerSwitch(id))
        if(id.isNotEmpty()) c.put("peerLibrary",id)
        peerSummary(c);vault.refresh()
    }
    fun createPeerLibrary(personal: Boolean = true, name: String = "Family library") = action { c ->
        require(c.optString("group").isNotEmpty() && (!personal || !c.has("peerLibrary")))
        val result = vault.command(CoreRequest.relayPeerCreate(c.getString("device"), personal = personal, transportKey = publicKey(c), name = name, migrateLegacy = true))
        c.put("peerLibrary", result.getString("library")).put("peers", JSONObject()).put("paused", false)
        if(!personal) {vault.command(CoreRequest.relayPeerSwitch(result.getString("library")));vault.refresh()}
        peerSummary(c)
        mutable.value = mutable.value.copy(reply = JSONObject().put("kind", "peer-v2-invite").put("personal",personal).put("library", result.getString("library")).put("founderKey", result.getString("publicKey")).put("device", c.getString("device")).put("transportKey", publicKey(c)).put("group", c.getString("group")).put("endpoint", c.getString("endpoint")).toString())
    }
    fun preparePeerJoin(text:String,confirmPersonal:Boolean=false)=action { c ->
        val invitation=JSONObject(text)
        require(invitation.opt("personal") is Boolean)
        val personal=invitation.getBoolean("personal")
        require((!personal||confirmPersonal)&&!c.has("peerExpectedLibrary")&&invitation.getString("kind")=="peer-v2-invite"&&invitation.getString("group")==c.getString("group")&&invitation.getString("endpoint")==c.getString("endpoint"))
        val result=vault.command(CoreRequest.relayPeerIdentity(c.getString("device"), personal = personal, confirmPersonalSync = confirmPersonal))
        c.put("peerPreviousLibrary",c.optString("peerLibrary")).put("peerPreviousPeers",JSONObject(c.getJSONObject("peers").toString())).put("peerPreviousPaused",c.optBoolean("paused",true))
        c.put("peerLibrary",result.getString("library")).put("peerPendingLocalLibrary",result.getString("library")).put("peerExpectedLibrary",invitation.getString("library")).put("peerFounderKey",invitation.getString("founderKey")).put("paused",false)
        c.getJSONObject("peers").put(invitation.getString("device"),invitation.getString("transportKey"))
        mutable.value=mutable.value.copy(reply=JSONObject().put("kind","peer-v2-request").put("personal",personal).put("library",invitation.getString("library")).put("device",c.getString("device")).put("publicKey",result.getString("publicKey")).put("transportKey",publicKey(c)).put("group",c.getString("group")).toString())
    }
    fun cancelPeerJoin()=action { c ->
        require(c.has("peerExpectedLibrary"))
        vault.command(CoreRequest.relayPeerCancelJoin(c.optString("peerPendingLocalLibrary",c.getString("peerLibrary"))))
        val previous=c.optString("peerPreviousLibrary");if(previous.isEmpty())c.remove("peerLibrary")else c.put("peerLibrary",previous)
        c.put("peers",c.optJSONObject("peerPreviousPeers")?:JSONObject()).put("paused",c.optBoolean("peerPreviousPaused",true))
        listOf("peerPendingLocalLibrary","peerExpectedLibrary","peerFounderKey","peerPreviousLibrary","peerPreviousPeers","peerPreviousPaused").forEach(c::remove)
        mutable.value=mutable.value.copy(reply="")
    }
    fun authorizePeerRequest(text: String, role: String = "editor") = action { c ->
        val request = JSONObject(text)
        require(role in setOf("admin", "editor", "reader") && request.getString("kind") == "peer-v2-request" && request.getString("library") == c.getString("peerLibrary") && request.getString("group") == c.getString("group"))
        vault.command(CoreRequest.relayPeerAuthorize(c.getString("peerLibrary"), request.getString("device"), member = JSONObject().put("publicKey", request.getString("publicKey")).put("transportKey", request.getString("transportKey")).put("role", role)))
        peerSummary(c)
    }
    fun rekeyPeerLibrary()=action { c ->
        require(c.optString("group").isNotEmpty())
        val result=vault.command(CoreRequest.relayPeerRekey(c.getString("peerLibrary"), c.getString("device"), publicKey(c)))
        c.put("peerLibrary",result.getString("library"))
        mutable.value=mutable.value.copy(reply=JSONObject().put("kind","peer-v2-invite").put("personal",result.optBoolean("personal",false)).put("library",result.getString("library")).put("founderKey",result.getString("publicKey")).put("device",c.getString("device")).put("transportKey",publicKey(c)).put("group",c.getString("group")).put("endpoint",c.getString("endpoint")).toString())
        peerSummary(c);vault.refresh()
    }
    fun resolvePeer(key: String, value: Any) = action { c ->
        vault.command(CoreRequest.relayPeerResolve(c.getString("peerLibrary"), key, value)); vault.refresh()
    }
    fun revokePeer(peer: String) = action { c ->
        // Omitting `member` is the registry's revoke form (core treats missing and null alike).
        vault.command(CoreRequest.relayPeerAuthorize(c.getString("peerLibrary"), peer)); peerSummary(c)
    }
    fun importCredential(text: String, endpoint: String) = action { c ->
        require(!c.has("groups"))
        val url = URI(endpoint)
        require(url.scheme == "wss" && url.host != null && (url.path == "/relay/v1/ws" || url.path == "/v2/ws") && url.rawUserInfo == null && url.query == null && url.fragment == null)
        val credential = JSONObject(text); val own = credential.getJSONObject("identity")
        require(own.getString("app") == "passwordvault" && own.getString("public_key") == publicKey(c))
        val current = vault.command(CoreRequest.relayStatus())
        if (current.optBoolean("enabled")) require(current.getString("group") == own.getString("group") && current.getString("device") == own.getString("device"))
        require(credential.getString("token").length >= 32)
        c.put("endpoint", endpoint).put("device", own.getString("device")).put("group", own.getString("group")).put("token", credential.getString("token"))
    }
    fun setUnlocked(value: Boolean) {
        if (value == unlocked) return
        unlocked = value
        if (!value) {
            epoch++; runCatching { client?.disconnect() }; loop?.cancel()
            config = null
            mutable.value = RelayUi(status = "已锁定 / Locked")
        } else scope.launch { actions.withLock { stop(); loadCredentials(); start() } }
    }
    suspend fun close() { unlocked = false; stop(); scope.cancel() }
    /**
     * The app returned to the foreground. Aggressive OEM power managers (e.g. HyperOS) freeze
     * backgrounded apps, so the relay drops the socket after missed pings; reconnect right away
     * instead of waiting out the retry backoff with a "waiting to reconnect" banner.
     */
    fun resume() {
        if (!unlocked) return
        val connection = client
        if (connection != null && !connection.isClosed() && loop?.isActive == true) return
        scope.launch { actions.withLock {
            if (!unlocked) return@withLock
            val current = client
            if (current != null && !current.isClosed() && loop?.isActive == true) return@withLock
            stop(); start()
        } }
    }
    fun syncNow() {
        val current = mutable.value
        val blocked = when {
            !unlocked || !current.paired || current.invalid || current.credentialsBlocked -> RelaySyncPhase.BLOCKED
            current.paused -> RelaySyncPhase.PAUSED
            else -> null
        }
        if (blocked != null) {
            mutable.value = current.copy(sync = current.sync.copy(phase = blocked))
            return
        }
        if (current.busy || current.sync.running) return
        mutable.value = current.copy(error = null, sync = current.sync.copy(phase = RelaySyncPhase.REQUESTED, completed = 0, total = 0))
        wake = true
        syncRequests.trySend(Unit)
        scope.launch { actions.withLock {
            if (loop?.isActive != true) start()
            if (unlocked && loop?.isActive != true) mutable.value = mutable.value.copy(sync = mutable.value.sync.copy(phase = RelaySyncPhase.BLOCKED))
        } }
    }
    private suspend fun stop() {
        epoch++; runCatching { client?.disconnect() }; loop?.cancelAndJoin(); loop = null
        mutable.value = mutable.value.copy(members = mutable.value.members.map { it.copy(online = false) },
            status = if (unlocked) "未连接 / Disconnected" else "已锁定 / Locked",
            sync = mutable.value.sync.copy(phase = RelaySyncPhase.IDLE, completed = 0, total = 0))
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
        // Delays follow the shared owner policy in vault-core (relay_protocol::policy).
        var backoff = 0L
        var connectedAt = 0L
        var rejected = false
        while (currentCoroutineContext().isActive && unlocked && generation == epoch) {
            var connection: RelayConnection? = null
            var failed = false
            connectedAt = 0L
            try {
                refreshGroupForConnection(c, generation)
                currentCoroutineContext().ensureActive()
                val connectionPeerKeys = c.getJSONObject("peers").toString()
                mutable.value = mutable.value.copy(status = "正在连接 / Connecting")
                progress(generation, RelaySyncPhase.CONNECTING)
                val options = relayOptions(c, journal = true)
                connection = runInterruptible(Dispatchers.IO) { RelayCore.connect(options) }
                client = connection
                val canSync = !c.optBoolean("paused", true) && c.getJSONObject("peers").length() > 0
                val connected = if (c.getJSONObject("peers").length() == 0) "中继已连接，等待组内其他设备 / Relay connected; waiting for other devices"
                    else if (!canSync) "中继已连接，密码库同步已暂停 / Relay connected; vault sync paused" else "已连接 / Connected"
                mutable.value = mutable.value.copy(status = connected,
                    error = mutable.value.error.takeUnless { it == transportFailure })
                transportFailure = null; connectedAt = System.currentTimeMillis()
                val fileClient = RelayCore.files(relayOptions(c, journal = false))
                val peerSent = mutableMapOf<String, String>()
                while (currentCoroutineContext().isActive && unlocked && generation == epoch) {
                    var capabilityBlocked = false
                    val meshPeers = meshRoster(c)?.also { ensureMesh(c, it) }
                    while (true) {
                        val event = runInterruptible(Dispatchers.IO) { connection.nextEvent(0u) }?.let(::JSONObject) ?: break
                        if (event.optString("type") == "message") {
                            val data = Base64.getDecoder().decode(event.getString("data"))
                            val from = event.getString("from")
                            val payload = JSONObject(String(data))
                            if (meshPeers != null) {
                                // Membership in the signed roster is the only admission step;
                                // old access/capability controls are ignored.
                                val format = payload.optString("format")
                                if (format != "passwordvault.capabilities.v1" && format != "passwordvault.access.v1" && from in meshPeers) {
                                    receiveMesh(data, from, generation)
                                }
                            } else if (c.has("peerLibrary")) {
                                // Peer libraries keep their own signed roster protocol.
                                val format = payload.optString("format")
                                if (format == "passwordvault.capabilities.v1" || format == "passwordvault.access.v1") { ack(connection, event); continue }
                                if (c.optBoolean("paused", true) || !c.getJSONObject("peers").has(from)) continue
                                try { receive(data, from, generation, c) }
                                catch (_: com.securepass.vault.core.VaultException.DevicesSyncBlocked) { capabilityBlocked = true; continue }
                            }
                            ack(connection, event)
                        } else if (event.optString("type") == "group.changed" && event.optInt("revision") >
                            (c.optJSONObject("groups")?.optJSONObject("group_entry")?.let { RelayCore.unpack(it).optInt("revision") } ?: 0)) throw IllegalStateException("Membership changed")
                        else if (event.optString("type") == "peer.up") peerSent.clear()
                    }
                    if (c.optJSONObject("groups")?.has("group_entry") == true) {
                        val devices = JSONObject(runInterruptible(Dispatchers.IO) { connection.peers() }).getJSONArray("devices")
                        currentCoroutineContext().ensureActive(); check(unlocked && generation == epoch)
                        val online = (0 until devices.length()).map { devices.getJSONObject(it) }
                            .filter { it.optString("app") == "passwordvault" && it.optString("group") == c.getString("group") }
                            .map { it.getString("device") }.toSet() + c.getString("device")
                        mutable.value = mutable.value.copy(members = mutable.value.members.map { it.copy(online = it.id in online) })
                    }
                    if (meshPeers != null) {
                        val forceSend = wake
                        wake = false
                        val retryNonce = if (forceSend) UUID.randomUUID().toString() else ""
                        progress(generation, RelaySyncPhase.CHECKING)
                        for (peer in meshPeers) {
                            val packet = vault.command(CoreRequest.relayMeshExport(peer)).optJSONObject("packet") ?: continue
                            val bytes = packet.toString().toByteArray()
                            val signature = hex(hash(bytes)) + ":" + System.currentTimeMillis()/3_600_000
                            if (peerSent[peer] == signature && !forceSend) continue
                            progress(generation, RelaySyncPhase.SENDING)
                            if (bytes.size <= 128*1024) runInterruptible(Dispatchers.IO) { connection.message(peer, bytes, true, relayDeliveryId(peer, signature, retryNonce)) }
                            else runInterruptible(Dispatchers.IO) { fileClient.send(peer, bytes) }
                            peerSent[peer] = signature
                            if (unlocked && generation == epoch) mutable.value = mutable.value.copy(sync = mutable.value.sync.copy(lastSentAt = System.currentTimeMillis()))
                        }
                        progress(generation, RelaySyncPhase.CHECKING)
                        val inbox = org.json.JSONArray(runInterruptible(Dispatchers.IO) { fileClient.inbox() })
                        for (index in 0 until inbox.length()) {
                            val file = inbox.getJSONObject(index); val from = file.getString("from")
                            require(from in meshPeers && file.getLong("size") <= 768L*1024*1024)
                            progress(generation, RelaySyncPhase.RECEIVING, index, inbox.length())
                            receiveMesh(runInterruptible(Dispatchers.IO) { fileClient.receive(file.toString()) }, from, generation)
                            runInterruptible(Dispatchers.IO) { fileClient.acknowledge(file.getString("id")) }
                            progress(generation, RelaySyncPhase.RECEIVING, index + 1, inbox.length())
                        }
                        if (unlocked && generation == epoch) mutable.value = mutable.value.copy(pending = 0, conflicts = 0,
                            sync = mutable.value.sync.copy(phase = RelaySyncPhase.CHECKED, completed = 0, total = 0, lastCheckedAt = System.currentTimeMillis()))
                    } else {
                    if (c.has("peerLibrary") && !c.optBoolean("paused", true) && c.getJSONObject("peers").length() > 0) {
                        val forceSend = wake
                        wake = false
                        val retryNonce = if (forceSend) UUID.randomUUID().toString() else ""
                        progress(generation, RelaySyncPhase.CHECKING)
                        val peerMode = c.has("peerLibrary")
                        val summary = if (peerMode) peerSummary(c) else vault.command(CoreRequest.relayStatus())
                        if (peerMode && c.optJSONObject("groups") == null && connectionPeerKeys != c.getJSONObject("peers").toString()) throw IllegalStateException("Authorized peer keys changed; reconnect")
                        mutable.value = mutable.value.copy(pending = summary.optInt("pending"), conflicts = if (peerMode) summary.optJSONObject("conflicts")?.length() ?: 0 else summary.optInt("conflictCount"), peerConflicts = summary.optJSONObject("conflicts")?.toString() ?: "{}")
                        val destinations = if (peerMode) c.getJSONObject("peers").keys().asSequence().toList() else listOf(c.getString("hub"))
                        for(peer in destinations) {
                          val libraries=if(peerMode) peerRosters.filterValues {it.has(peer)}.keys.toList() else listOf("")
                          for(library in libraries) {
                            val packet = try { vault.command(if(peerMode) CoreRequest.relayPeerExport(library, peer) else CoreRequest.relayExport(peer)).toString().toByteArray() }
                                catch (_: com.securepass.vault.core.VaultException.DevicesSyncBlocked) { capabilityBlocked = true; continue }
                            val signature = hex(hash(packet)) + ":" + System.currentTimeMillis()/3_600_000 + ":" + c.optLong("access_revision") + ":" + c.optJSONObject("capabilityReady")?.optString(peer).orEmpty()
                            val route=peer+":"+library
                            if (peerSent[route] != signature || forceSend) {
                                progress(generation, RelaySyncPhase.SENDING)
                                if (packet.size <= 128*1024) runInterruptible(Dispatchers.IO) { connection.message(peer, packet, true, relayDeliveryId(peer, signature, retryNonce)) }
                                else if (peerMode) {
                                    require(packet.size <= 48*1024*1024)
                                    val digest=hex(hash(packet));val count=(packet.size+65535)/65536
                                    for(index in 0 until count) {
                                        val part=packet.copyOfRange(index*65536,minOf(packet.size,(index+1)*65536))
                                        val chunk=JSONObject().put("protocol","peer-v2-chunk").put("library",library).put("transfer",digest.take(32)).put("index",index).put("count",count).put("total",packet.size).put("digest",digest).put("data",Base64.getEncoder().encodeToString(part))
                                        runInterruptible(Dispatchers.IO) { connection.message(peer,chunk.toString().toByteArray(),true,relayDeliveryId(route, signature + ":" + index, retryNonce)) }
                                        progress(generation, RelaySyncPhase.SENDING, index + 1, count)
                                        delay(25)
                                    }
                                } else runInterruptible(Dispatchers.IO) { fileClient.send(peer, packet) }
                                peerSent[route] = signature
                                if (unlocked && generation == epoch) mutable.value = mutable.value.copy(sync = mutable.value.sync.copy(lastSentAt = System.currentTimeMillis()))
                            }
                          }
                        }
                        progress(generation, RelaySyncPhase.CHECKING)
                        val inbox = org.json.JSONArray(runInterruptible(Dispatchers.IO) { fileClient.inbox() })
                        for (index in 0 until inbox.length()) {
                            val file = inbox.getJSONObject(index); val from = file.getString("from")
                            require(c.getJSONObject("peers").has(from) && (peerMode || from == c.getString("hub")) && file.getLong("size") <= 768L*1024*1024)
                            try {
                                progress(generation, RelaySyncPhase.RECEIVING, index, inbox.length())
                                receive(runInterruptible(Dispatchers.IO) { fileClient.receive(file.toString()) }, from, generation, c)
                                runInterruptible(Dispatchers.IO) { fileClient.acknowledge(file.getString("id")) }
                                progress(generation, RelaySyncPhase.RECEIVING, index + 1, inbox.length())
                            } catch (_: com.securepass.vault.core.VaultException.DevicesSyncBlocked) {
                                capabilityBlocked = true
                                // Leave the encrypted file pending until capability negotiation completes.
                            }
                        }
                        val latest = if (peerMode) peerSummary(c) else vault.command(CoreRequest.relayStatus())
                        if (unlocked && generation == epoch) {
                            val pending = latest.optInt("pending")
                            mutable.value = mutable.value.copy(pending = pending,
                                conflicts = if (peerMode) latest.optJSONObject("conflicts")?.length() ?: 0 else latest.optInt("conflictCount"),
                                sync = mutable.value.sync.copy(phase = completedSyncPhase(pending, peerMode, capabilityBlocked), completed = 0, total = 0, lastCheckedAt = System.currentTimeMillis()))
                        }
                    } else progress(generation, if (c.optBoolean("paused", true)) RelaySyncPhase.PAUSED else RelaySyncPhase.BLOCKED)
                    }
                    withTimeoutOrNull(5000) { syncRequests.receive() }
                }
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                if (error is CancellationException && error !is TimeoutCancellationException) throw error
                failed = true
                android.util.Log.w("PersonalRelay", "sync loop failed: ${RelayCore.code(error)}", error)
                val decision = retryDecision(error, backoff, connectedAt)
                rejected = decision.optBoolean("stop")
                backoff = decision.optLong("delay", 30)
                if (unlocked && generation == epoch) {
                    transportFailure = when {
                        rejected -> "同步服务拒绝凭据，已停止重连；请检查服务器密码后重试 / Sync access rejected; reconnecting stopped. Check the server password and retry"
                        error is java.net.UnknownHostException -> "无法解析同步服务器，请检查网络 / Cannot resolve sync server; check network"
                        error is java.net.SocketTimeoutException || error is TimeoutCancellationException || error is java.util.concurrent.TimeoutException -> "同步连接或传输超时，本地改动已保留 / Sync timed out; local changes retained"
                        error is javax.net.ssl.SSLException -> "无法验证同步服务器的安全连接 / Cannot verify the sync server's secure connection"
                        error.message.orEmpty().contains("(401)") -> "同步服务拒绝凭据，请检查服务器密码 / Sync access rejected; check server password"
                        else -> "同步未完成，本地改动已保留，请检查网络及其他设备状态 / Sync incomplete; local changes retained. Check the network and your other devices (${RelayCore.code(error)})"
                    }
                    mutable.value = mutable.value.copy(status = "等待重连 / Waiting to reconnect", error = mutable.value.error ?: transportFailure,
                        sync = mutable.value.sync.copy(phase = RelaySyncPhase.FAILED, completed = 0, total = 0))
                }
            }
            finally {
                connection?.disconnect(); if (client === connection) client = null
                if (generation == epoch) mutable.value = mutable.value.copy(members = mutable.value.members.map { it.copy(online = false) })
            }
            if (mutable.value.invalid || rejected) return
            if (!failed) backoff = retryDecision(null, backoff, connectedAt).optLong("delay", 1)
            withTimeoutOrNull(backoff * 1000) { syncRequests.receive() }
        }
    }
    /** Shared retry policy from vault-core: 401/403 stop; otherwise 1 s doubling to 30 s, reset only after 120 s connected. */
    private fun retryDecision(error: Throwable?, previous: Long, connectedAt: Long): JSONObject {
        val connected = if (connectedAt == 0L) 0L else (System.currentTimeMillis() - connectedAt) / 1000
        val request = CoreRequest.relayProtocolRetry(error?.message ?: error?.javaClass?.simpleName ?: "closed", previousDelay = previous, connectedSeconds = connected)
        return runCatching { JSONObject(com.securepass.vault.core.relayProtocol(request.toString())) }
            .getOrElse { JSONObject().put("stop", false).put("delay", 30) }
    }
    /** Signed-roster members with pinned keys, excluding this device; null when not in a personal group. */
    private fun meshRoster(c: JSONObject): List<String>? {
        if (c.has("peerLibrary")) return null
        val g = c.optJSONObject("groups") ?: return null
        val entry = g.optJSONObject("group_entry") ?: return null
        if (g.optBoolean("access_invalid")) return null
        val state = RelayCore.unpack(entry)
        if (state.optBoolean("closed")) return null
        val trusted = g.optJSONObject("trusted_peers") ?: JSONObject()
        val members = state.getJSONArray("members")
        return (0 until members.length()).map { members.getJSONObject(it).getString("device") }
            .filter { it != c.getString("device") && trusted.optString(it).isNotEmpty() }
    }
    private suspend fun ensureMesh(c: JSONObject, peers: List<String>) {
        vault.command(CoreRequest.relayMeshInit(c.getString("group"), c.getString("device")))
        vault.command(CoreRequest.relayMeshPeers(org.json.JSONArray(peers)))
    }
    /** Applies a symmetric-sync packet; older protocol packets are ignored until that device updates. */
    private suspend fun receiveMesh(data: ByteArray, from: String, generation: Int): Boolean {
        check(unlocked && generation == epoch)
        val packet = JSONObject(String(data))
        if (packet.optInt("version") != 3 || packet.optString("kind") != "mesh") return false
        progress(generation, RelaySyncPhase.RECEIVING)
        val result = try { vault.command(CoreRequest.relayMeshReceive(from, packet)) } catch (error: com.securepass.vault.core.VaultException) {
            // Debug builds only, opt-in (instrumented probe): keep the rejected packet in app-private cache to reproduce it.
            if (BuildConfig.DEBUG && RelayLocalTest.capturePackets) File(storage.parentFile, "mesh-rejected-${System.currentTimeMillis()}.json").writeText(packet.toString())
            throw error
        }
        val changed = result.optBoolean("changed")
        // Invalid individual records are skipped by vault-core; log their keys (ids only).
        result.optJSONArray("rejected")?.takeIf { it.length() > 0 }?.let { android.util.Log.w("PersonalRelay", "mesh records skipped from $from: $it") }
        check(unlocked && generation == epoch)
        if (changed) vault.refresh()
        mutable.value = mutable.value.copy(lastReceived = System.currentTimeMillis(), pending = 0, conflicts = 0)
        return changed
    }
    private suspend fun receive(data: ByteArray, hub: String, generation: Int, c: JSONObject) {
        check(unlocked && generation == epoch)
        progress(generation, RelaySyncPhase.RECEIVING)
        if (c.has("peerLibrary")) {
            val incomingEnvelope=JSONObject(String(data));val incomingLibrary=incomingEnvelope.optJSONObject("packet")?.getString("library") ?: incomingEnvelope.getString("library")
            if (c.has("peerExpectedLibrary") && incomingLibrary==c.getString("peerExpectedLibrary")) {
                val result = vault.command(CoreRequest.relayPeerJoin(c.optString("peerPendingLocalLibrary",c.getString("peerLibrary")), envelope = JSONObject(String(data)), expectedLibrary = c.getString("peerExpectedLibrary"), founderKey = c.getString("peerFounderKey"), sender = hub))
                if(result.optBoolean("partial"))return
                c.put("peerLibrary", result.getString("library")); listOf("peerPendingLocalLibrary","peerExpectedLibrary","peerFounderKey","peerPreviousLibrary","peerPreviousPeers","peerPreviousPaused").forEach(c::remove); config = c; save(c)
            } else {
                val registered=vault.command(CoreRequest.relayPeerList()).getJSONArray("libraries")
                if((0 until registered.length()).none {registered.getJSONObject(it).getString("id")==incomingLibrary})return
                val current = vault.command(CoreRequest.relayPeerStatus(incomingLibrary))
                if(current.optBoolean("frozen"))return
                require(current.getJSONObject("members").getJSONObject(hub).getString("transportKey") == c.getJSONObject("peers").getString(hub))
                val result=vault.command(CoreRequest.relayPeerReceive(incomingLibrary, JSONObject(String(data)), sender = hub))
                if(result.optBoolean("partial"))return
            }
        } else vault.command(CoreRequest.relayReceive(hub, JSONObject(String(data))))
        check(unlocked && generation == epoch)
        vault.refresh()
        val summary = if (c.has("peerLibrary")) peerSummary(c) else vault.command(CoreRequest.relayStatus())
        mutable.value = mutable.value.copy(lastReceived = System.currentTimeMillis(), pending = summary.optInt("pending"), conflicts = summary.optInt("conflictCount"))
    }
    private suspend fun ack(connection: RelayConnection, event: JSONObject) {
        runInterruptible(Dispatchers.IO) { connection.acknowledge(event.getString("from"), event.getString("id"), event.optBoolean("offline")) }
    }
    /** The vault-core group state machine; drafts persist into the relay credentials before each request. */
    private fun groups(c: JSONObject): CoreGroups {
        check(c.has("groups") || c.optString("token").isEmpty()) { "Legacy access requires explicit reset" }
        val g = c.optJSONObject("groups") ?: JSONObject().put("app", "passwordvault")
            .put("device", c.getString("device")).put("secret_key", c.getString("secret"))
            .put("url", "wss://relay.example.test/relay/v1/ws")
        return CoreGroups(g, { draft -> c.put("groups", draft); runBlocking { save(c) } }, RelayLocalTest.active)
    }
    private suspend fun saveGroup(c: JSONObject, g: CoreGroups) { c.put("groups", g.config); save(c) }
    private suspend fun applyGroup(c: JSONObject, g: CoreGroups, online: org.json.JSONArray = org.json.JSONArray()) {
        saveGroup(c, g)
        check(unlocked)
        val entry = g.config.optJSONObject("group_entry") ?: return
        val group = RelayCore.unpack(entry); val members = group.getJSONArray("members")
        if (group.optBoolean("closed") || (0 until members.length()).none { members.getJSONObject(it).getString("device") == c.getString("device") }) {
            invalidateGroup(c); error("Group access revoked")
        }
        c.put("endpoint", g.config.getString("url")).put("group", g.config.getString("group")).put("token", g.config.getString("token"))
        if (g.config.has("password")) c.put("password", g.config.getString("password"))
        val trusted = g.config.getJSONObject("trusted_peers"); val peers = c.getJSONObject("peers")
        for (id in peers.keys().asSequence().toList()) if (trusted.optString(id) != peers.getString(id)) {
            if (!c.has("peerLibrary")) vault.command(CoreRequest.relayRevoke(id)); peers.remove(id)
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
    private fun groupAction(block: suspend (JSONObject, CoreGroups) -> Unit) { scope.launch {
        actions.withLock {
            if (!unlocked) return@withLock
            mutable.value = mutable.value.copy(busy = true, error = null)
            stop()
            try {
                val c = checkNotNull(config); val g = groups(c)
                try { withContext(Dispatchers.IO) { block(c, g) } } catch (error: Exception) { saveGroup(c, g); throw error }
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
        g.create(name, deviceName); applyGroup(c, g)
        mutable.value = mutable.value.copy(status = "设备组已创建，可邀请其他设备扫码加入 / Group created; invite your other devices")
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
        val joined = g.join(inv, deviceName); saveGroup(c, g)
        if (inv.optString("mode") == "auto") {
            check(joined || g.finishJoin()); applyGroup(c, g)
            mutable.value = mutable.value.copy(status = "已入组，正在与组内设备同步 / Joined; syncing with the group")
        } else mutable.value = mutable.value.copy(status = "请核对两端配对码 / Compare codes on both devices")
    }
    fun updateServerEndpoint(endpoint: String) = action { c ->
        val url = validateRelayEndpoint(endpoint)
        c.put("endpoint", url)
        c.optJSONObject("groups")?.put("url", url)
        save(c)
        val stored = c.optJSONObject("groups")
        if (stored?.has("group_entry") == true) {
            val g = groups(c)
            val result = withContext(Dispatchers.IO) { g.refresh() }
            applyGroup(c, g, result.getJSONArray("online"))
            g.config.remove("access_invalid")
            saveGroup(c, g)
        }
    }
    // Updating server access never resets device identity, pinned keys, or vault authorization.
    fun updateServerPassword(password: String) = action { c ->
        updateRelayAccessCredential(c, password)
        save(c)
        val stored = c.optJSONObject("groups")
        if (stored?.has("group_entry") == true) {
            // Old clients treated all HTTP 401s as revocation. Recover only after a verified refresh.
            val g = groups(c)
            val result = withContext(Dispatchers.IO) { g.refresh() }
            applyGroup(c, g, result.getJSONArray("online"))
            g.config.remove("access_invalid")
            saveGroup(c, g)
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
        val name = RelayCore.unpack(pending.getJSONObject("request")).getJSONObject("member").getString("name")
        val joined = g.join(pending.getJSONObject("invitation"), name); saveGroup(c, g)
        if (pending.getJSONObject("invitation").optString("mode") == "auto" && (joined || g.finishJoin())) applyGroup(c, g)
    }
    fun finishGroupJoin() = groupAction { c, g ->
        if (g.finishJoin()) {
            applyGroup(c, g)
            mutable.value = mutable.value.copy(status = "已入组，正在与组内设备同步 / Joined; syncing with the group")
        } else mutable.value = mutable.value.copy(status = "等待邀请方批准 / Waiting for approval")
    }
    fun refreshGroup() = groupAction { c, g -> val result = g.refresh(); applyGroup(c, g, result.getJSONArray("online")) }
    fun inviteToGroup(automatic: Boolean = true) = groupAction { c, g ->
        // Reuses a still-valid invitation and its short link; publishing is retried idempotently.
        g.invite(automatic)
        applyGroup(c, g)
    }
    fun checkGroupRequest() = groupAction { c, g ->
        require(g.config.getJSONObject("issued_invitation").optString("mode") != "auto")
        g.pending()
        val result = g.refresh(); applyGroup(c, g, result.getJSONArray("online"))
        if (!g.config.has("join_request")) mutable.value = mutable.value.copy(status = "尚无加入申请 / No request yet")
    }
    fun approveGroupRequest(manager: Boolean) = groupAction { c, g ->
        g.approve(manager); applyGroup(c, g)
    }
    fun cancelGroupInvitation() = groupAction { c, g ->
        g.cancel(); applyGroup(c, g)
    }
    fun renameGroupMember(device: String, name: String) = groupAction { c, g -> g.rename(device, name); applyGroup(c, g) }
    fun removeGroupMember(device: String) = groupAction { c, g -> g.remove(device); applyGroup(c, g) }
    fun leaveGroup(disband: Boolean) {
        scope.launch {
            var remoteSnapshot: JSONObject? = null
            var generation = 0
            actions.withLock {
                if (!unlocked) return@withLock
                mutable.value = mutable.value.copy(busy = true, error = null)
                stop()
                try {
                    val c = checkNotNull(config)
                    val groupsJson = c.optJSONObject("groups")
                    if (groupsJson?.has("group_entry") == true) {
                        // Never orphan a group: validate the signed exit before clearing locally.
                        withContext(Dispatchers.IO) { CoreGroups(JSONObject(groupsJson.toString()), { }, RelayLocalTest.active).checkExit(disband) }
                        remoteSnapshot = JSONObject(groupsJson.toString())
                    }
                    clearGroupAccess(c)
                    generation = epoch
                    publish()
                    mutable.value = mutable.value.copy(
                        status = exitPendingMessage(disband, remoteSnapshot != null)
                    )
                } catch (cancel: CancellationException) {
                    throw cancel
                } catch (error: Exception) {
                    publish()
                    mutable.value = mutable.value.copy(error = relayFailure(error))
                } finally {
                    mutable.value = mutable.value.copy(busy = false)
                }
            }
            // Best-effort remote notification using only the detached snapshot; never restores local membership.
            val snapshot = remoteSnapshot ?: return@launch
            val confirmed = runCatching {
                // The detached snapshot never persists: it cannot restore local membership.
                val sdk = CoreGroups(snapshot, { }, RelayLocalTest.active)
                if (!sdk.config.optBoolean("exit_completed")) withContext(Dispatchers.IO) { sdk.exit(disband) }
                true
            }.getOrDefault(false)
            if (unlocked && generation == epoch) {
                mutable.value = mutable.value.copy(status = exitResultMessage(disband, confirmed))
            }
        }
    }
    fun clearLocalGroup() = action { c -> check(unlocked); clearGroupAccess(c) }
    private suspend fun clearGroupAccess(c: JSONObject) {
        val old = vault.command(CoreRequest.relayStatus())
        if (old.optBoolean("enabled")) vault.command(CoreRequest.relayDetach(old.getString("group"), old.getString("device")))
        val previous = JSONObject(c.toString())
        c.remove("access_revision"); c.remove("access_enabled")
        // Owner policy (vault-core relay_protocol::policy): clear credentials, keep the endpoint,
        // rotate the device ID and — unless a peer library still pins it — the transport key.
        val fresh = JSONObject(com.securepass.vault.core.relayProtocol(CoreRequest.relayProtocolExitIdentity().toString()))
        c.remove("groups"); c.remove("password"); c.put("group", "").put("token", "").put("hub", "").put("peers", JSONObject())
            .put("paused", true).put("device", fresh.getString("device"))
        if (c.optString("peerLibrary").isEmpty()) c.put("secret", fresh.getString("secret"))
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
                val g = groups(c); val result = withContext(Dispatchers.IO) { g.refresh() }
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

    companion object {
        internal fun exitPendingMessage(disband: Boolean, hasRemote: Boolean): String = when {
            !hasRemote -> "本机接入已清除，本地资料保留 / Local access cleared; vault retained"
            disband -> "本机已退出，正在尝试通知服务器解散设备组 / Left locally; notifying server to disband"
            else -> "本机已退出，正在尝试通知服务器 / Left locally; notifying server"
        }
        internal fun exitResultMessage(disband: Boolean, confirmed: Boolean): String = when {
            confirmed && disband -> "本机已退出，服务器已确认解散设备组 / Left locally; server confirmed disband"
            confirmed -> "本机已退出，服务器已确认退出 / Left locally; server confirmed"
            disband -> "本机已退出，服务器解散未完成 / Left locally; server disband not confirmed"
            else -> "本机已退出，服务器尚未确认退出 / Left locally; server exit not confirmed"
        }
        private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
        private fun hex(bytes: ByteArray) = RelayCore.hex(bytes)
        private fun encrypt(bytes: ByteArray, key: SecretKey): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.ENCRYPT_MODE, key); iv + doFinal(bytes) }
        private fun decrypt(bytes: ByteArray, key: SecretKey): ByteArray = Cipher.getInstance("AES/GCM/NoPadding").run { require(bytes.size >= 28); init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0,12))); doFinal(bytes.copyOfRange(12,bytes.size)) }
    }
}
