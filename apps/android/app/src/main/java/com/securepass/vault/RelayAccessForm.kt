package com.securepass.vault

import java.net.URI
import org.json.JSONObject

/** Local inspection only. Reading/scanning an invitation never sends a join request. */
internal data class RelayInvitationPreview(val input: String, val endpoint: String, val password: String) {
    companion object {
        fun read(text: String): RelayInvitationPreview {
            val input = text.trim()
            require(input.toByteArray().size <= 16384) { "邀请过长 / Invitation too long" }
            if (input.startsWith("common-relay:")) {
                val parsed = RelayCore.protocol(CoreRequest.relayProtocolParseLink(input, allowLocal = RelayLocalTest.active))
                return RelayInvitationPreview(input, validateRelayEndpoint(parsed.getString("url")), parsed.optString("password").takeUnless { parsed.isNull("password") }.orEmpty())
            }
            val invitation = JSONObject(input)
            require(invitation.getInt("version") == 1 && invitation.getString("app") == "passwordvault")
            require(invitation.getLong("expires") > System.currentTimeMillis() / 1000) { "邀请已失效 / Invitation expired" }
            return RelayInvitationPreview(input, validateRelayEndpoint(invitation.getString("url")), invitation.optString("password"))
        }
    }
}

/** Debug builds only: instrumented tests may point the relay at ws://127.0.0.1 (via adb reverse). */
internal object RelayLocalTest {
    @Volatile var enabled = false
    /** Debug-only probe: store packets the core rejects in app-private cache for local reproduction. */
    @Volatile var capturePackets = false
    val active: Boolean get() = enabled && BuildConfig.DEBUG
}

internal fun validateRelayEndpoint(text: String): String {
    val value = text.trim()
    val uri = URI(value)
    val local = RelayLocalTest.active && uri.scheme == "ws" && uri.host == "127.0.0.1"
    require((uri.scheme == "wss" || local) && !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null && (uri.path == "/relay/v1/ws" || uri.path == "/v2/ws")) {
        "请输入 wss://服务器/v2/ws 或 wss://服务器/relay/v1/ws / Enter a WSS relay endpoint"
    }
    return value
}

internal fun validateRelayPassword(value: String): String {
    require(value.isNotEmpty()) { "请输入服务器密码 / Server password required" }
    // Relay-Access rule shared with vault-core: 8-128 printable ASCII characters.
    require(value.length in 8..128 && value.all { it.code in 0x21..0x7e }) { "服务器密码需为 8-128 位可见 ASCII 字符 / Server password must be 8-128 printable ASCII characters" }
    return value
}

/** Validate before mutation; a server credential update must not replace signed identity state. */
internal fun updateRelayAccessCredential(config: JSONObject, password: String) {
    validateRelayPassword(password)
    config.put("password", password)
    config.optJSONObject("groups")?.let { group ->
        group.put("password", password)
        group.optJSONObject("pending_join")?.getJSONObject("invitation")?.put("password", password)
    }
}
