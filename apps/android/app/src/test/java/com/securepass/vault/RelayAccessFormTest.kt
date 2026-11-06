package com.securepass.vault

import java.util.Base64
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RelayAccessFormTest {
    private val key = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 1 })
    private val id = Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(16) { 2 })
    private val link = "common-relay://relay.example.test/i/$id#$key"

    @Test fun readsCarriedPasswordLocallyAndSupportsOldLink() {
        val access = "fixture-access-123"
        val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(access.toByteArray())
        val preview = RelayInvitationPreview.read("$link.$encoded")
        assertEquals("wss://relay.example.test/relay/v1/ws", preview.endpoint)
        assertEquals(access, preview.password)
        assertEquals("", RelayInvitationPreview.read(link).password)
        assertThrows(IllegalArgumentException::class.java) { validateRelayPassword("") }
        assertEquals("replacement-456", validateRelayPassword("replacement-456"))
    }

    @Test fun rejectsWrongEndpointsAndMalformedInvitations() {
        for (endpoint in listOf("", "https://relay.example.test/relay/v1/ws", "wss://user@relay.example.test/relay/v1/ws", "wss://relay.example.test/relay/v1/ws?secret=x", "wss:///relay/v1/ws", "wss://relay.example.test/other")) {
            assertThrows(Exception::class.java) { validateRelayEndpoint(endpoint) }
        }
        for (input in listOf("https://relay.example.test/i/demo#demo", "$link.", "$link.%%%")) {
            assertThrows(Exception::class.java) { RelayInvitationPreview.read(input) }
        }
    }

    @Test fun legacyInvitationChecksAppExpiryAndPreservesInput() {
        val value = JSONObject().put("version", 1).put("app", "passwordvault")
            .put("expires", System.currentTimeMillis()/1000 + 600)
            .put("url", "wss://relay.example.test/relay/v1/ws")
        val input = value.toString()
        assertEquals(input, RelayInvitationPreview.read(input).input)
        assertEquals("", RelayInvitationPreview.read(input).password)
        value.put("app", "other")
        assertThrows(Exception::class.java) { RelayInvitationPreview.read(value.toString()) }
        value.put("app", "passwordvault").put("expires", 1)
        assertThrows(Exception::class.java) { RelayInvitationPreview.read(value.toString()) }
    }
    @Test fun passwordUpgradeKeepsSignedIdentityAndPendingRequest() {
        val invitation = JSONObject().put("password", "old-pass-123")
        val group = JSONObject().put("device", "original-device").put("secret_key", "private-key-fixture")
            .put("group_entry", JSONObject().put("signature", "signed-membership"))
            .put("vault_authority", JSONObject().put("public_key", "pinned-key"))
            .put("pending_join", JSONObject().put("invitation", invitation).put("request", "signed-request"))
        val config = JSONObject().put("device", "original-device").put("secret", "private-key-fixture")
            .put("token", "device-token").put("groups", group).put("access_revision", 7)
        val previous = config.toString()
        assertThrows(IllegalArgumentException::class.java) { updateRelayAccessCredential(config, "") }
        assertEquals(previous, config.toString())
        updateRelayAccessCredential(config, "corrected-pass-456")
        val restored = JSONObject(config.toString())
        assertEquals("corrected-pass-456", restored.getString("password"))
        assertEquals("corrected-pass-456", restored.getJSONObject("groups").getJSONObject("pending_join").getJSONObject("invitation").getString("password"))
        assertEquals("original-device", restored.getString("device"))
        assertEquals("private-key-fixture", restored.getString("secret"))
        assertEquals("device-token", restored.getString("token"))
        assertEquals(7, restored.getInt("access_revision"))
        assertEquals("signed-membership", restored.getJSONObject("groups").getJSONObject("group_entry").getString("signature"))
        assertEquals("pinned-key", restored.getJSONObject("groups").getJSONObject("vault_authority").getString("public_key"))
        assertEquals("signed-request", restored.getJSONObject("groups").getJSONObject("pending_join").getString("request"))
    }
}
