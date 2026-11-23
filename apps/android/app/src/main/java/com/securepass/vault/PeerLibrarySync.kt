package com.securepass.vault

import org.json.JSONObject

/** A library-specific adapter. Delivery must use authenticated pairwise encryption.
 * Relay group discovery never grants membership in this library. */
internal class PeerLibrarySync(
    val library: String,
    private val device: String,
    private val command: suspend (JSONObject) -> JSONObject,
    private val deliver: suspend (String, String, ByteArray) -> Unit,
) {
    private val sent = mutableMapOf<String, String>()
    suspend fun status(): JSONObject = command(CoreRequest.relayPeerStatus(library))

    suspend fun synchronize() {
        val state = status()
        check(!state.optBoolean("frozen")) { "Library permission conflict requires recovery" }
        val members = state.optJSONObject("members") ?: return
        for (peer in members.keys().asSequence().toList()) {
            if (peer == device) continue
            val transportKey = members.getJSONObject(peer).optString("transportKey")
            if (transportKey.isEmpty()) continue
            val packet = command(CoreRequest.relayPeerExport(library, peer)).toString()
            if (sent[peer] == packet) continue
            deliver(peer, transportKey, packet.toByteArray(Charsets.UTF_8))
            // Only a delivery cache: it does not claim remote application or all-device sync.
            sent[peer] = packet
        }
    }

    suspend fun receive(data: ByteArray, from: String, authenticatedTransportKey: String) {
        val state = status()
        check(!state.optBoolean("frozen"))
        val member = state.optJSONObject("members")?.optJSONObject(from)
        check(authenticatedTransportKey.isNotEmpty() && member?.optString("transportKey") == authenticatedTransportKey)
        command(CoreRequest.relayPeerReceive(library, JSONObject(String(data, Charsets.UTF_8))))
    }

    suspend fun resolve(key: String, value: Any) {
        command(CoreRequest.relayPeerResolve(library, key, value))
        resetDeliveryCache()
    }

    suspend fun authorize(peer: String, signingKey: String, transportKey: String, role: String) {
        require(role in setOf("admin", "editor", "reader") && transportKey.isNotEmpty())
        command(CoreRequest.relayPeerAuthorize(library, peer, member =
            JSONObject().put("publicKey", signingKey).put("transportKey", transportKey).put("role", role)))
        resetDeliveryCache()
    }

    suspend fun revoke(peer: String) {
        // Omitting `member` is the registry's revoke form (core treats missing and null alike).
        command(CoreRequest.relayPeerAuthorize(library, peer))
        resetDeliveryCache()
    }

    fun resetDeliveryCache() { sent.clear() }
}
