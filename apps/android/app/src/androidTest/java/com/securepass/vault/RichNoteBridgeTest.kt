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
class RichNoteBridgeTest {
    @Test fun localEditorCapturesRichDocumentAndRejectsWrongToken() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val directory = File(context.cacheDir, "rich-bridge-${UUID.randomUUID()}")
        val vault = VaultRepository(context, directory)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        var session: AndroidNoteSession? = null
        try {
            withTimeout(20_000) { while (!vault.state.value.ready) delay(20) }
            vault.authenticate("synthetic rich bridge fixture", true)
            val note = VaultRepository.blank("secureNote").put("title", "Synthetic rich note").put("note", "Original")
            assertTrue(vault.save(note))
            instrumentation.runOnMainSync { session = AndroidNoteSession(context, note, vault, scope, { _, english -> english }, {}, { _, _ -> }, {}) }
            val editor = session!!
            suspend fun evaluate(script: String): String {
                val result = CompletableDeferred<String>()
                instrumentation.runOnMainSync { editor.view.evaluateJavascript(script) { result.complete(it) } }
                return withTimeout(10_000) { result.await() }
            }
            withTimeout(20_000) { while (evaluate("!!document.querySelector('[contenteditable=true]')") != "true") delay(50) }
            evaluate("window.pvEditor.command('selectAll');window.pvEditor.command('toggleBold');document.execCommand('insertText',false,'RICH_BRIDGE_CANARY')")
            delay(150)
            evaluate("VaultNoteBridge.postMessage(JSON.stringify({token:'wrong-token',kind:'change',source:'ATTACK',revision:99}))")
            delay(50)
            val captured = JSONObject(withTimeout(5000) { editor.capture(false).await() }!!)
            assertEquals("rich-v1", captured.getString("noteFormat"))
            assertEquals("RICH_BRIDGE_CANARY", captured.getString("note"))
            assertTrue(captured.getJSONObject("noteDocument").toString().contains("bold"))
            assertTrue(vault.save(captured))
            vault.captureRichDraft = { editor.capture(true) }
            vault.lock()
            vault.authenticate("synthetic rich bridge fixture", false)
            assertTrue(vault.state.value.unlocked)
            assertEquals("RICH_BRIDGE_CANARY", JSONObject(vault.pendingDraft!!).getString("note"))
            assertEquals("rich-v1", vault.state.value.entries.single().getString("noteFormat"))
            vault.discardDraft()
        } finally {
            instrumentation.runOnMainSync { session?.discard() }
            scope.cancel(); vault.close(); directory.deleteRecursively()
        }
    }
}
