package com.securepass.vault

import io.github.junweiup.commonrelay.CoreProtocol
import org.json.JSONObject

/** Routes the common-relay SDK's protocol work (group chain, signing, invitations,
 * envelopes) to the shared Rust implementation in vault-core. */
internal object RelayProtocolBridge {
    init {
        CoreProtocol.install { request -> JSONObject(com.securepass.vault.core.relayProtocol(request.toString())) }
    }

    fun install() = Unit
}
