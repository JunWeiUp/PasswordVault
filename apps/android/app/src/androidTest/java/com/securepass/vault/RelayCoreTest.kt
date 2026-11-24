package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.securepass.vault.core.RelayException
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** The relay stack (protocol, groups, WSS, files, journal) lives in vault-core; exercise its Android binding. */
@RunWith(AndroidJUnit4::class)
class RelayCoreTest {
    @Test fun invitationPreviewAndOwnerPolicyComeFromCore() {
        val encode = { b: ByteArray -> java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b) }
        val link = "common-relay://relay.example.test/v2/i/${encode(ByteArray(16) { 2 })}#${encode(ByteArray(32) { 1 })}"
        val preview = RelayInvitationPreview.read("$link.${encode("fixture-access-123".toByteArray())}")
        assertEquals("wss://relay.example.test/v2/ws", preview.endpoint)
        assertEquals("fixture-access-123", preview.password)
        assertEquals("", RelayInvitationPreview.read(link).password)
        for (input in listOf("$link.", "$link.%%%")) assertThrows(Exception::class.java) { RelayInvitationPreview.read(input) }

        assertTrue(RelayCore.protocol(CoreRequest.relayProtocolRetry("RelayHttp401", 4, 0)).getBoolean("stop"))
        assertEquals(8, RelayCore.protocol(CoreRequest.relayProtocolRetry("RelayConnection", 4, 10)).getInt("delay"))
        val a = RelayCore.protocol(CoreRequest.relayProtocolExitIdentity())
        assertEquals(64, a.getString("secret").length)
        assertEquals(64, RelayCore.publicKey(a.getString("secret")).length)
        assertFalse(a.getJSONArray("cleared").toString().contains("endpoint"))
    }

    /**
     * Two in-process devices over a real Common Relay on the host:
     * `adb reverse tcp:PORT tcp:PORT` and `-e relayUrl ws://127.0.0.1:PORT/v2/ws -e relayPassword ...`.
     */
    @Test fun groupMessagesAndFilesOverALiveRelay() {
        val args = InstrumentationRegistry.getArguments()
        val url = args.getString("relayUrl"); val password = args.getString("relayPassword")
        assumeTrue("relayUrl not provided", url != null && password != null)
        val dir = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir.resolve("relay-live-${System.nanoTime()}")
        fun device(name: String) = JSONObject().put("app", "passwordvault").put("url", url).put("device", name)
            .put("secret_key", RelayCore.hex(RelayCore.random(32))).put("password", password)
        // Device IDs are global on a v2 relay: use fresh ones so reruns against one server do not collide.
        val macId = java.util.UUID.randomUUID().toString(); val phoneId = java.util.UUID.randomUUID().toString()
        val mac = CoreGroups(device(macId), {}, allowLocal = true)
        mac.create("Home", "Mac")
        val link = mac.invite(automatic = true)
        val phone = CoreGroups(device(phoneId), {}, allowLocal = true)
        val invitation = phone.resolveInvitation(link, null)
        assertTrue(phone.join(invitation, "Phone"))
        assertEquals(2, mac.refresh().getJSONObject("state").getJSONArray("members").length())

        fun options(g: CoreGroups, journal: String) = RelayCore.options(g.config.getString("url"), g.config.getString("token"), password,
            g.config.getString("group"), g.config.getString("device"), g.config.getString("secret_key"),
            g.config.getJSONObject("trusted_peers").let { t -> t.keys().asSequence().associateWith { t.getString(it) } },
            dir.resolve(journal), allowLocal = true)
        val a = RelayCore.connect(options(mac, "a")); val b = RelayCore.connect(options(phone, "b"))
        try {
            assertTrue(JSONObject(a.peers()).getJSONArray("devices").toString().contains(phoneId))
            a.message(phoneId, "hello".toByteArray(), true, "0123456789abcdef0123456789abcdef")
            var event: JSONObject? = null
            repeat(100) { if (event == null) event = b.nextEvent(100u)?.let(::JSONObject)?.takeIf { it.optString("type") == "message" } }
            assertEquals("aGVsbG8=", event!!.getString("data"))
            b.acknowledge(macId, event!!.getString("id"), event!!.optBoolean("offline"))

            val files = RelayCore.files(options(mac, "fa")); val inbox = RelayCore.files(options(phone, "fb"))
            val payload = ByteArray(200_000) { 7 }
            files.send(phoneId, payload)
            val pending = org.json.JSONArray(inbox.inbox())
            assertEquals(1, pending.length())
            assertArrayEquals(payload, inbox.receive(pending.getJSONObject(0).toString()))
            inbox.acknowledge(pending.getJSONObject(0).getString("id"))
        } finally { a.disconnect(); b.disconnect(); a.close(); b.close() }
        phone.exit(false)
        assertEquals(1, mac.refresh().getJSONObject("state").getJSONArray("members").length())
        val wrong = JSONObject(options(mac, "w")).put("password", "wrong-relay-access").toString()
        val error = assertThrows(RelayException.Failed::class.java) { RelayCore.connect(wrong) }
        assertTrue(RelayCore.protocol(CoreRequest.relayProtocolRetry(error.code)).getBoolean("stop"))
        dir.deleteRecursively()
    }
}
