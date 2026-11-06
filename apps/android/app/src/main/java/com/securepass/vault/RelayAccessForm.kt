package com.securepass.vault

import io.github.junweiup.commonrelay.InvitationLinks
import io.github.junweiup.commonrelay.RelayAccess
import java.net.URI
import org.json.JSONObject

/** Local inspection only. Reading/scanning an invitation never sends a join request. */
internal data class RelayInvitationPreview(val input: String, val endpoint: String, val password: String) {
    companion object {
        fun read(text: String): RelayInvitationPreview {
            val input = text.trim()
            require(input.toByteArray().size <= 16384) { "邀请过长 / Invitation too long" }
            if (input.startsWith("common-relay:")) {
                val parsed = InvitationLinks.parse(input, false)
                try { return RelayInvitationPreview(input, validateRelayEndpoint(parsed.url), parsed.password.orEmpty()) }
                finally { parsed.key.fill(0) }
            }
            val invitation = JSONObject(input)
            require(invitation.getInt("version") == 1 && invitation.getString("app") == "passwordvault")
            require(invitation.getLong("expires") > System.currentTimeMillis() / 1000) { "邀请已失效 / Invitation expired" }
            return RelayInvitationPreview(input, validateRelayEndpoint(invitation.getString("url")), invitation.optString("password"))
        }
    }
}

internal fun validateRelayEndpoint(text: String): String {
    val value = text.trim()
    val uri = URI(value)
    require(uri.scheme == "wss" && !uri.host.isNullOrBlank() && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null && uri.path == "/relay/v1/ws") {
        "请输入 wss://服务器/relay/v1/ws / Enter a WSS relay endpoint"
    }
    return value
}

internal fun validateRelayPassword(value: String): String {
    require(value.isNotEmpty()) { "请输入服务器密码 / Server password required" }
    RelayAccess.validate(value)
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
