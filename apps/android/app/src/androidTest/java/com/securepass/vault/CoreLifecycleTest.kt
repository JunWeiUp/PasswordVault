package com.securepass.vault

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.securepass.vault.core.VaultSession
import java.io.File
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CoreLifecycleTest {
    @Test
    fun encryptedPersistenceAndFailurePaths() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val directory = File(context.cacheDir, "core-test-${UUID.randomUUID()}").apply { mkdirs() }
        fun command(core: VaultSession, op: String, values: JSONObject = JSONObject()): JSONObject =
            JSONObject(core.command(values.put("op", op).toString()))
        try {
            VaultSession(directory.absolutePath).use { core ->
                command(core, "create", JSONObject().put("password", "Synthetic Android 123!"))
                val item =
                    VaultRepository.blank("secureNote")
                        .put("title", "ANDROID_TITLE_CANARY_271")
                        .put("note", "ANDROID_BODY_CANARY_803")
                command(core, "save", JSONObject().put("item", item))
                val backup =
                    command(core, "export", JSONObject().put("password", "Separate backup 123!"))
                        .getString("content")
                assertThrows(Exception::class.java) {
                    command(
                        core,
                        "import",
                        JSONObject().put("content", backup).put("password", "wrong"),
                    )
                }
                assertEquals(1, command(core, "list").getJSONArray("items").length())
                directory
                    .walkTopDown()
                    .filter { it.isFile }
                    .forEach { file ->
                        val bytes = file.readBytes().toString(Charsets.ISO_8859_1)
                        assertFalse(bytes.contains("ANDROID_TITLE_CANARY_271"))
                        assertFalse(bytes.contains("ANDROID_BODY_CANARY_803"))
                    }
                command(core, "lock")
                assertThrows(Exception::class.java) { command(core, "list") }
            }
            VaultSession(directory.absolutePath).use { core ->
                command(core, "unlock", JSONObject().put("password", "Synthetic Android 123!"))
                assertEquals(
                    "ANDROID_BODY_CANARY_803",
                    command(core, "list").getJSONArray("items").getJSONObject(0).getString("note"),
                )
            }
        } finally {
            directory.deleteRecursively()
        }
    }
}
