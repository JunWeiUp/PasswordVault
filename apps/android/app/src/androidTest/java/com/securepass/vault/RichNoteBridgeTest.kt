package com.securepass.vault

import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.activity.compose.setContent
import androidx.test.core.app.ActivityScenario
import androidx.test.uiautomator.UiDevice
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
    @Test fun mountedRichEditorShowsBottomScrollableToolbarAndCapturesSyntheticScreenshot() = runBlocking {
        org.junit.Assume.assumeTrue(android.os.Build.VERSION.SDK_INT >= 29)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val directory = File(context.cacheDir, "rich-editor-screen-${UUID.randomUUID()}")
        val activityVaultId = UUID.randomUUID().toString()
        val vault = VaultRepository(context, directory)
        var scenario: ActivityScenario<MainActivity>? = null
        fun find(view: View): WebView? {
            if (view is WebView) return view
            if (view is ViewGroup) for (index in 0 until view.childCount) find(view.getChildAt(index))?.let { return it }
            return null
        }
        suspend fun evaluate(view: WebView, script: String): String {
            val answer = CompletableDeferred<String>()
            instrumentation.runOnMainSync { view.evaluateJavascript(script) { answer.complete(it) } }
            return withTimeout(10_000) { answer.await() }
        }
        try {
            withTimeout(20_000) { while (!vault.state.value.ready) delay(20) }
            vault.authenticate("synthetic rich screenshot fixture", true)
            assertTrue(vault.mutate("settings", JSONObject().put("settings", JSONObject().put("theme", "light"))))
            val note = VaultRepository.blank("secureNote").put("title", "Weekend plans · synthetic fixture")
                .put("noteFormat", "rich-v1").put("note", "Fictional rich editor screenshot")
                .put("noteDocument", JSONObject("""{"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"A quiet weekend"}]},{"type":"paragraph","content":[{"type":"text","text":"Walk by the river, "},{"type":"text","text":"read a new book","marks":[{"type":"bold"}]},{"type":"text","text":" and leave room for small ideas."}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Visit the local library"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"Sketch a simple garden plan"}]}]}]}]}"""))
            assertTrue(vault.save(note))
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", activityVaultId).putExtra("qaScreenshots", true),
            )
            scenario.onActivity { activity -> activity.setContent { LegacyVaultTheme(dark = false) { RichNoteEditor(note, vault, { _, english -> english }, {}) } } }
            var webView: WebView? = null
            withTimeout(20_000) {
                while (true) {
                    instrumentation.runOnMainSync {
                        webView = android.view.inspector.WindowInspector.getGlobalWindowViews().asSequence().mapNotNull { find(it) }.firstOrNull { it.isShown }
                    }
                    val candidate = webView
                    if (candidate != null && evaluate(candidate, "!!document.querySelector('[contenteditable=true]')") == "true") break
                    delay(50)
                }
            }
            val editor = webView!!
            assertEquals("true", evaluate(editor, "(function(){const t=document.querySelector('.toolbar'),r=t.getBoundingClientRect();return r.height>=48&&r.height<80&&Math.abs(r.bottom-innerHeight)<=2&&getComputedStyle(t).overflowX==='auto'&&t.scrollWidth>t.clientWidth})()"))
            assertEquals("true", evaluate(editor, "getComputedStyle(document.querySelector('.ProseMirror')).fontSize==='14px'&&getComputedStyle(document.querySelector('.ProseMirror')).lineHeight==='24px'"))
            assertEquals("true", evaluate(editor, "(function(){const x=a=>document.querySelector('.toolbar [data-action=\\\"'+a+'\\\"]').getBoundingClientRect().left;return x('toggleBold')<x('insertTable')&&x('toggleBold')<x('find')})()"))
            assertEquals("true", evaluate(editor, "(function(){const t=document.querySelector('.toolbar');t.scrollLeft=t.scrollWidth;return t.scrollLeft>0})()"))
            evaluate(editor, "document.querySelector('.toolbar').scrollLeft=0")
            val frame = CompletableDeferred<Unit>()
            instrumentation.runOnMainSync {
                assertTrue("Editor must have visible bounds", editor.isShown && editor.width > 0 && editor.height > 0)
                editor.postVisualStateCallback(1L, object : WebView.VisualStateCallback() {
                    override fun onComplete(requestId: Long) { frame.complete(Unit) }
                })
            }
            withTimeout(10_000) { frame.await() }
            val device = UiDevice.getInstance(instrumentation)
            assertTrue("Native title must be on screen", device.wait(androidx.test.uiautomator.Until.hasObject(androidx.test.uiautomator.By.text(note.getString("title"))), 8_000))
            instrumentation.waitForIdleSync()
            delay(500) // Allow the completed WebView frame to reach the screenshot compositor.
            assertTrue(device.takeScreenshot(File(context.getExternalFilesDir(null), "align-noteEdit-rich.png")))
        } finally {
            scenario?.close()
            vault.captureRichDraft = null
            vault.close()
            directory.deleteRecursively()
            File(context.cacheDir, "ui-test-$activityVaultId").deleteRecursively()
        }
    }

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
