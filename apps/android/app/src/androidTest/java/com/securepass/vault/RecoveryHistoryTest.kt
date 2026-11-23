package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RecoveryHistoryTest {
    @Test fun restoreAndHistoryPreserveDataAndAllowOneCharacterPassword() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(context.cacheDir, "recovery-${UUID.randomUUID()}")
        val target = File(context.cacheDir, "recovery-${UUID.randomUUID()}")
        val vault = VaultRepository(context, source)
        val restored = VaultRepository(context, target)
        try {
            withTimeout(10000) { while (!vault.state.value.ready || !restored.state.value.ready) delay(10) }
            vault.authenticate("original", true)
            val item = VaultRepository.blank("secureNote").put("title", "Fixture").put("note", "Original")
            assertTrue(vault.save(item))
            vault.command(CoreRequest.historyEnable())
            assertTrue(vault.save(JSONObject(item.toString()).put("note", "Edited")))
            val key = vault.command(CoreRequest.recoveryGenerate()).getString("key")
            vault.command(CoreRequest.recoveryEnable("original", key))
            vault.pendingDraft = item.toString()
            try { vault.command(CoreRequest.recoveryExport(key)); fail("Pending draft ignored") } catch (_: Exception) {}
            vault.pendingDraft = null
            val archive = vault.command(CoreRequest.recoveryExport(key)).getString("content")
            restored.recover("bad", "x", archive)
            assertFalse(restored.state.value.unlocked)
            context.getSharedPreferences("biometric-key", 0).edit().putString("ciphertext", "synthetic enrollment").commit()
            restored.recover(key, "x", archive)
            assertTrue(restored.state.value.unlocked)
            assertFalse(context.getSharedPreferences("biometric-key", 0).contains("ciphertext"))
            assertEquals("Edited", restored.state.value.entries.first().getString("note"))
            val rows = restored.command(CoreRequest.historyList(item.getString("id"))).getJSONArray("revisions")
            assertEquals(2, rows.length())
            restored.command(CoreRequest.historyRestore(item.getString("id"), rows.getJSONObject(1).getString("id"), java.time.Instant.now().toString()))
            restored.refresh()
            assertEquals("Original", restored.state.value.entries.first().getString("note"))
            restored.command(CoreRequest.export("Long backup fixture"))
            Unit
        } finally { vault.close(); restored.close(); source.deleteRecursively(); target.deleteRecursively() }
    }
}
