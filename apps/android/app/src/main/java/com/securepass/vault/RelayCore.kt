package com.securepass.vault

import com.securepass.vault.core.RelayConnection
import com.securepass.vault.core.RelayException
import com.securepass.vault.core.RelayFileClient
import com.securepass.vault.core.RelayGroupStore
import com.securepass.vault.core.relayGroups
import com.securepass.vault.core.relayProtocol
import java.security.MessageDigest
import java.security.SecureRandom
import org.json.JSONArray
import org.json.JSONObject

/**
 * Thin Android adapter over vault-core's relay implementation (protocol, group state machine,
 * WSS connection, files, journal). Every call is blocking: use it from Dispatchers.IO.
 */
internal object RelayCore {
    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
    fun unhex(text: String): ByteArray {
        require(text.length % 2 == 0) { "Invalid hex" }
        return ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
    fun random(count: Int): ByteArray = ByteArray(count).also { SecureRandom().nextBytes(it) }
    fun digest(bytes: ByteArray): String = hex(MessageDigest.getInstance("SHA-256").digest(bytes))

    fun protocol(request: JSONObject): JSONObject = JSONObject(relayProtocol(request.toString()))

    /** Envelope (X25519) public key for a hex transport secret. */
    fun publicKey(secretHex: String): String = protocol(CoreRequest.relayProtocolKeys(secretHex)).getString("publicKey")

    /** Strictly parsed state of a signed group entry. */
    fun unpack(entry: JSONObject): JSONObject = protocol(CoreRequest.relayProtocolUnpack(entry)).getJSONObject("state")

    /** `{url, token, password?, identity, journal?}` for [RelayConnection]/[RelayFileClient]. */
    fun options(url: String, token: String, password: String?, group: String, device: String, secretHex: String,
                trusted: Map<String, String>, journal: java.io.File? = null, allowLocal: Boolean = false): String =
        JSONObject().put("url", url).put("token", token).put("allowLocal", allowLocal)
            .apply { if (!password.isNullOrEmpty()) put("password", password); if (journal != null) put("journal", journal.absolutePath) }
            .put("identity", JSONObject().put("app", "passwordvault").put("group", group).put("device", device)
                .put("secret", secretHex).put("trusted", JSONObject(trusted)))
            .toString()

    fun connect(options: String): RelayConnection = RelayConnection.connect(options)
    fun files(options: String): RelayFileClient = RelayFileClient(options)

    /** Relay error code (`RelayHttp401`, `RelayConnection`, ...) for the shared retry policy. */
    fun code(error: Throwable): String = (error as? RelayException.Failed)?.code ?: error.message ?: error.javaClass.simpleName
}

/**
 * The vault-core group state machine for one config. [persist] must durably store each draft
 * before the call that commits it returns (it is invoked from inside the blocking call).
 */
internal class CoreGroups(var config: JSONObject, private val persist: (JSONObject) -> Unit, private val allowLocal: Boolean = false) {
    private val store = object : RelayGroupStore {
        override fun save(config: String) {
            val value = JSONObject(config)
            this@CoreGroups.config = value
            persist(value)
        }
    }

    private fun run(op: String, fill: JSONObject.() -> Unit = {}): Any? {
        val request = JSONObject().put("op", op).put("config", config).put("allowLocal", allowLocal).apply(fill)
        val reply = JSONObject(relayGroups(request.toString(), store))
        config = reply.getJSONObject("config")
        return reply.opt("result")
    }

    fun create(name: String, deviceName: String) { run("create") { put("name", name).put("deviceName", deviceName) } }
    /** Resolves a compact link; a non-empty [override] replaces the link's server password. */
    fun resolveInvitation(link: String, override: String?): JSONObject =
        run("resolve") { put("link", link); if (!override.isNullOrEmpty()) put("override", override) } as JSONObject
    fun join(invitation: JSONObject, name: String): Boolean = run("join") { put("invitation", invitation).put("name", name) } == true
    fun finishJoin(): Boolean = run("finish-join") == true
    /** `{state, online}` after verifying the chain. */
    fun refresh(): JSONObject = run("refresh") as JSONObject
    /** Short link for a fresh or still-valid invitation. */
    fun invite(automatic: Boolean): String = run("invite") { put("mode", if (automatic) "auto" else "manual") } as String
    fun pending() { run("pending") }
    fun code(): String = run("code") as String
    /** The UI shows [code] on both devices; approving confirms they match. */
    fun approve(manager: Boolean) { val code = code(); run("approve") { put("code", code).put("manager", manager) } }
    fun cancel() { run("cancel") }
    fun rename(device: String, name: String) { run("rename") { put("device", device).put("name", name) } }
    fun remove(device: String) { run("remove") { put("device", device) } }
    fun exit(disband: Boolean) { run("exit") { put("disband", disband) } }
    /** Offline check that the signed exit is allowed (e.g. not the last manager leaving others). */
    fun checkExit(disband: Boolean) { run("check-exit") { put("disband", disband) } }
    fun member(name: String): JSONObject = run("member") { put("name", name) } as JSONObject
}
