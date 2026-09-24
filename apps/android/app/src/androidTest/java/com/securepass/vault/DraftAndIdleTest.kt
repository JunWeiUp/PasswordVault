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
class DraftAndIdleTest {
    @Test
    fun draftWriteFailureAndCorruptionDoNotLoseVaultAccess() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "draft-test-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("Synthetic draft 123!", true)
            val draft =
                VaultRepository.blank("secureNote")
                    .put("title", "DRAFT_TITLE_CANARY")
                    .put("note", "DRAFT_BODY_CANARY")
            vault.pendingDraft = draft.toString()
            File(directory, "mobile-draft.sealed").mkdir()
            vault.lock()
            vault.authenticate("Synthetic draft 123!", false)
            assertTrue(vault.state.value.unlocked)
            assertEquals(
                "DRAFT_BODY_CANARY",
                JSONObject(vault.state.value.recoveredDraft!!).getString("note"),
            )
            assertTrue(vault.state.value.entries.isEmpty())
            vault.discardDraft()
            File(directory, "mobile-draft.sealed").writeText("invalid draft")
            vault.lock()
            vault.authenticate("Synthetic draft 123!", false)
            assertTrue(vault.state.value.unlocked)
            assertNotNull(vault.state.value.error)
        } finally {
            vault.close()
            directory.deleteRecursively()
        }
    }

    @Test
    fun backgroundTotpComputationDoesNotExtendIdleTimeout() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "idle-test-${UUID.randomUUID()}")
        var now = 0L
        val vault = VaultRepository(context, directory) { now }
        try {
            withTimeout(10_000) { while (!vault.state.value.ready) delay(10) }
            vault.authenticate("Synthetic idle 123!", true)
            vault.mutate(
                "settings",
                JSONObject().put("settings", JSONObject().put("autoLockMinutes", 1)),
            )
            now = 59_000
            vault.command(
                "totp",
                JSONObject().put("secret", "JBSWY3DPEHPK3PXP").put("period", 30).put("time", 59),
            )
            now = 60_001
            vault.checkIdle()
            assertFalse(vault.state.value.unlocked)
        } finally {
            vault.close()
            directory.deleteRecursively()
        }
    }
}
