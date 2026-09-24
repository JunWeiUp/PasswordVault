package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class EntryHistoryTest {
    @Test
    fun restoredDraftKeepsPrimaryAndAdditionalPasswordHistory() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "history-test-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        try {
            while (!vault.state.value.ready) delay(10)
            vault.authenticate("1", true)
            val saved =
                VaultRepository.blank("password")
                    .put("title", "History fixture")
                    .put("password", "previous-primary")
                    .put(
                        "passwordHistory",
                        JSONArray().put(JSONObject().put("password", "older-primary")),
                    )
                    .put(
                        "accounts",
                        JSONArray()
                            .put(JSONObject().put("id", "extra").put("password", "previous-extra")),
                    )
            assertTrue(vault.save(saved))
            val edited = JSONObject(saved.toString()).put("password", "next-primary")
            edited.getJSONArray("accounts").getJSONObject(0).put("password", "next-extra")
            vault.pendingDraft = edited.toString()
            // This is the original passed to the editor after Activity/composition reconstruction.
            val reopenedDraft = JSONObject(vault.pendingDraft!!)
            assertTrue(vault.save(prepareEntrySave(reopenedDraft, vault.state.value.entries)))
            // Retrying the original recovered snapshot must neither lose nor duplicate history.
            assertTrue(vault.save(prepareEntrySave(reopenedDraft, vault.state.value.entries)))
            val fresh =
                prepareEntrySave(
                    VaultRepository.blank("password").put("password", "new"),
                    emptyList(),
                )
            assertTrue(fresh.optString("passwordLastChanged").isNotEmpty())
            vault.discardDraft()
            vault.lock()
            vault.authenticate("1", false)
            val restored = vault.state.value.entries.single()
            assertEquals("next-primary", restored.optString("password"))
            assertEquals(
                "previous-primary",
                restored.getJSONArray("passwordHistory").getJSONObject(0).getString("password"),
            )
            assertEquals(
                "older-primary",
                restored.getJSONArray("passwordHistory").getJSONObject(1).getString("password"),
            )
            assertEquals(
                "previous-extra",
                restored
                    .getJSONArray("accounts")
                    .getJSONObject(0)
                    .getJSONArray("passwordHistory")
                    .getJSONObject(0)
                    .getString("password"),
            )
        } finally {
            vault.close()
            directory.deleteRecursively()
        }
    }
}
