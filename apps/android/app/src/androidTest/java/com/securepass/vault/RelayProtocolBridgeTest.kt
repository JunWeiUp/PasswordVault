package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.junweiup.commonrelay.Crypto
import io.github.junweiup.commonrelay.InvitationLinks
import io.github.junweiup.commonrelay.RelayGroups
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/** The common-relay SDK delegates protocol work to vault-core; exercise that bridge on device. */
@RunWith(AndroidJUnit4::class)
class RelayProtocolBridgeTest {
    private val url = "ws://127.0.0.1:1/relay/v1/ws"

    @Before fun install() = RelayProtocolBridge.install()

    private fun groups(device: String) = RelayGroups(
        JSONObject().put("app", "passwordvault").put("url", url).put("device", device)
            .put("secret_key", Crypto.hex(Crypto.random(32))), true,
    )

    private fun next(entry: JSONObject, change: (JSONObject) -> Unit): JSONObject {
        val state = RelayGroups.unpack(entry)
        state.put("revision", state.getInt("revision") + 1)
            .put("previous", RelayGroups.digest(RelayGroups.payload(entry)))
            .put("invitation", "").put("request_hash", "")
        change(state)
        return state
    }

    @Test fun groupChainSigningAndStrictRulesRunInCore() {
        val mac = groups("mac")
        val phone = groups("phone")
        mac.prepareCreate("Home", "Mac")
        val created = mac.config.getJSONObject("pending_create")
        val founder = RelayGroups.unpack(created).getJSONArray("members").getJSONObject(0)
        assertEquals(mac.member("").getString("signing_key"), founder.getString("signing_key"))
        RelayGroups.verify(created, founder.getString("signing_key"))
        mac.accept(created)

        val joined = mac.sign(next(created) { s ->
            s.getJSONArray("members").put(phone.member("Phone"))
            s.put("invitation", Crypto.hex(Crypto.random(16))).put("request_hash", Crypto.hex(Crypto.random(32)))
        })
        assertEquals(joined.toString(), mac.advance(created, joined).toString())

        // Owner decision: a member's signing_key can never be replaced in place.
        val backfill = mac.sign(next(joined) { s ->
            s.getJSONArray("members").getJSONObject(1).put("signing_key", "11".repeat(32))
        })
        assertThrows(Exception::class.java) { mac.advance(joined, backfill) }
        val renamed = mac.sign(next(joined) { s -> s.getJSONArray("members").getJSONObject(1).put("name", "Pixel") })
        mac.advance(joined, renamed)
        val forged = JSONObject(renamed.toString()).put("signature", "00".repeat(64))
        assertThrows(Exception::class.java) { mac.advance(joined, forged) }
        val left = phone.sign(next(renamed) { s -> s.put("members", JSONArray().put(founder)) })
        mac.advance(renamed, left)
    }

    @Test fun envelopesAndInvitationLinksRunInCore() {
        val a = Crypto.hex(Crypto.random(32))
        val b = Crypto.hex(Crypto.random(32))
        val aPublic = Crypto("passwordvault", "g", "a", a, emptyMap()).publicKey()
        val bPublic = Crypto("passwordvault", "g", "b", b, emptyMap()).publicKey()
        val alice = Crypto("passwordvault", "g", "a", a, mapOf("b" to bPublic))
        val bob = Crypto("passwordvault", "g", "b", b, mapOf("a" to aPublic))
        val body = alice.seal("b", "message", "m1", JSONObject().put("data", "aGk="))
        assertEquals("aGk=", bob.open("a", "message", "m1", body).getString("data"))
        assertThrows(Exception::class.java) { bob.open("a", "message", "m2", body) }
        assertThrows(Exception::class.java) { bob.open("x", "message", "m1", body) }

        val invitation = JSONObject().put("version", 1).put("url", url).put("id", Crypto.hex(Crypto.random(16)))
        val key = Crypto.random(32)
        val link = InvitationLinks.make(invitation, key, "Access-Pass-1")
        val parsed = InvitationLinks.parse(link, true)
        assertEquals(url, parsed.url)
        assertEquals(invitation.getString("id"), parsed.id)
        assertArrayEquals(key, parsed.key)
        assertEquals("Access-Pass-1", parsed.password)
        assertThrows(Exception::class.java) { InvitationLinks.parse("$link&x", true) }
        val packet = InvitationLinks.seal(invitation, key, Crypto.random(24))
        val opened = JSONObject(InvitationLinks.open(packet, key).toString())
        for (name in listOf("version", "url", "id")) assertEquals(invitation.get(name), opened.get(name))
        assertEquals(3, opened.length())
        assertThrows(Exception::class.java) { InvitationLinks.open(packet, Crypto.random(32)) }
        assertEquals(64, InvitationLinks.readToken(key).length)
    }

    @Test fun invitationPreviewReadsCompactLinksThroughCore() {
        val encode = { b: ByteArray -> java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b) }
        val link = "common-relay://relay.example.test/i/${encode(ByteArray(16) { 2 })}#${encode(ByteArray(32) { 1 })}"
        val access = "fixture-access-123"
        val preview = RelayInvitationPreview.read("$link.${encode(access.toByteArray())}")
        assertEquals("wss://relay.example.test/relay/v1/ws", preview.endpoint)
        assertEquals(access, preview.password)
        assertEquals("", RelayInvitationPreview.read(link).password)
        for (input in listOf("$link.", "$link.%%%")) {
            val error = runCatching { RelayInvitationPreview.read(input) }.exceptionOrNull()
            assertNotNull(error)
            assertFalse("core must reject, not be missing", error is IllegalStateException)
        }
    }
}
