package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalSyncTest {
    @Test
    fun authorizedPeerReceivesEncryptedPacketAndLocksStopServer() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val base = File(context.cacheDir, "sync-test-${UUID.randomUUID()}").apply { mkdirs() }
        val owner = VaultRepository(context, File(base, "owner"))
        val member = VaultRepository(context, File(base, "member"))
        try {
            withTimeout(10_000) {
                while (!owner.state.value.ready || !member.state.value.ready) delay(20)
            }
            owner.authenticate("Owner fake password 123!", true)
            member.authenticate("Member fake password 123!", true)
            val ownerKey = owner.command("identity").getString("publicKey")
            val memberKey = member.command("identity").getString("publicKey")
            val shared =
                owner
                    .command(
                        "create-shared",
                        JSONObject()
                            .put("name", "Synthetic shared")
                            .put("time", "2024-01-01T00:00:00Z"),
                    )
                    .getString("id")
            owner.command(
                "add-member",
                JSONObject()
                    .put("vaultId", shared)
                    .put("publicKey", memberKey)
                    .put("role", "viewer")
                    .put("name", "QA member"),
            )
            val item =
                VaultRepository.blank("secureNote")
                    .put("title", "SHARED_CANARY_TITLE")
                    .put("note", "SHARED_CANARY_BODY")
                    .put("sharedVaultId", shared)
            assertTrue(owner.save(item))
            owner.sync.start()
            withTimeout(10_000) { while (owner.sync.endpoint.value.isEmpty()) delay(20) }
            val request =
                member.command(
                    "sync-request",
                    JSONObject().put("peerKey", ownerKey).put("vaultId", shared),
                )
            assertFalse(request.toString().contains("SHARED_CANARY"))
            val response = LocalSync.exchange(owner.sync.endpoint.value, request)
            assertFalse(response.toString().contains("SHARED_CANARY"))
            member.command(
                "sync-apply",
                JSONObject().put("packet", response).put("peerKey", ownerKey).put("vaultId", shared),
            )
            member.refresh()
            assertEquals(
                "SHARED_CANARY_BODY",
                member.state.value.entries.single().getString("note"),
            )
            assertFalse(
                member.save(JSONObject(item.toString()).put("note", "Viewer must not write"))
            )
            owner.lock()
            assertEquals("", owner.sync.endpoint.value)
        } finally {
            owner.close()
            member.close()
            base.deleteRecursively()
        }
    }
}
