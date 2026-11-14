package com.securepass.vault

import android.content.Intent
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebView
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Real shared-editor rendering against an isolated encrypted vault, never a user's library. */
@RunWith(AndroidJUnit4::class)
class RichNoteReaderTest {
    @Test
    fun inlineRichOriginalIsReadOnlyRejectsBridgeWritesAndUnloadsWhenPrivate() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val directory = File(context.cacheDir, "rich-reader-${UUID.randomUUID()}")
        val activityVaultId = UUID.randomUUID().toString()
        val activityDirectory = File(context.cacheDir, "ui-test-$activityVaultId")
        val vault = VaultRepository(context, directory)
        var scenario: ActivityScenario<MainActivity>? = null
        var activity: MainActivity? = null
        fun findWebView(view: View?): WebView? {
            if (view is WebView) return view
            if (view is ViewGroup) for (index in 0 until view.childCount) {
                findWebView(view.getChildAt(index))?.let { return it }
            }
            return null
        }
        fun currentWebView(): WebView? {
            var result: WebView? = null
            instrumentation.runOnMainSync { result = findWebView(activity?.window?.decorView) }
            return result
        }
        suspend fun evaluate(view: WebView, script: String): String {
            val answer = CompletableDeferred<String>()
            instrumentation.runOnMainSync { view.evaluateJavascript(script) { answer.complete(it) } }
            return withTimeout(10_000) { answer.await() }
        }
        suspend fun readyReader(): WebView {
            var result: WebView? = null
            withTimeout(20_000) {
                while (true) {
                    val candidate = currentWebView()
                    if (candidate != null && evaluate(candidate, "!!document.querySelector('.tiptap h2')") == "true") {
                        result = candidate
                        break
                    }
                    delay(50)
                }
            }
            return result!!
        }
        suspend fun noReader() {
            withTimeout(10_000) { while (currentWebView() != null) delay(25) }
        }
        try {
            withTimeout(20_000) { while (!vault.state.value.ready) delay(20) }
            vault.authenticate("synthetic read-only rich fixture", true)
            val note = VaultRepository.blank("secureNote").put("title", "Read-only rich fixture")
            assertTrue(vault.save(note))
            val bitmap = android.graphics.Bitmap.createBitmap(1, 1, android.graphics.Bitmap.Config.ARGB_8888)
            val png = java.io.ByteArrayOutputStream().use { output ->
                assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            }
            bitmap.recycle()
            val attachment = vault.importNoteAttachment(note.getString("id"), "fixture.png", "image/png", png)
            val document = JSONObject().put("type", "doc").put("content", JSONArray()
                .put(JSONObject().put("type", "heading").put("attrs", JSONObject().put("level", 2)).put("content", JSONArray().put(text("INLINE_RICH_HEADING"))))
                .put(JSONObject().put("type", "paragraph").put("content", JSONArray().put(text("FULL_ORIGINAL_BODY", bold = true))))
                .put(JSONObject().put("type", "bulletList").put("content", JSONArray().put(JSONObject().put("type", "listItem").put("content", JSONArray().put(JSONObject().put("type", "paragraph").put("content", JSONArray().put(text("Original list item"))))))))
                .put(JSONObject().put("type", "vaultImage").put("attrs", JSONObject().put("attachmentId", attachment.getString("id")).put("name", "fixture.png").put("mime", "image/png").put("width", 64).put("caption", "Encrypted fixture image"))))
            note.put("noteFormat", "rich-v1").put("noteDocument", document).put("note", "SUMMARY_MUST_NOT_REPLACE_DOCUMENT")
            assertTrue(vault.save(note))
            val persisted = vault.state.value.entries.single { it.optString("id") == note.getString("id") }
            val original = persisted.toString()
            assertNull(vault.pendingDraft)
            scenario = ActivityScenario.launch(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    .putExtra("uiTestVault", activityVaultId).putExtra("qaScreenshots", true),
            )
            scenario.onActivity {
                activity = it
                it.setContent { MaterialTheme { NoteReader(persisted, vault, { _, english -> english }, {}, {}) } }
            }
            val first = readyReader()
            assertEquals("false", evaluate(first, "document.querySelector('.tiptap').getAttribute('contenteditable')").trim('"'))
            assertEquals("true", evaluate(first, "document.querySelector('.tiptap strong').textContent === 'FULL_ORIGINAL_BODY' && document.querySelector('.tiptap li').textContent === 'Original list item'"))
            assertEquals("false", evaluate(first, "document.querySelector('.tiptap').textContent.includes('SUMMARY_MUST_NOT_REPLACE_DOCUMENT')"))
            assertEquals("true", evaluate(first, "getComputedStyle(document.querySelector('.toolbar')).display === 'none'"))
            withTimeout(10_000) {
                while (evaluate(first, "!!document.querySelector('img') && document.querySelector('img').complete && document.querySelector('img').naturalWidth === 1") != "true") delay(50)
            }
            // Obtain this session's real resource token: rejecting only wrong-token messages is insufficient.
            evaluate(first, "window.readerTestToken=document.querySelector('img').getAttribute('src').split('/')[2];VaultNoteBridge.postMessage(JSON.stringify({token:readerTestToken,kind:'change',revision:999,source:'FORGED_BODY'}));VaultNoteBridge.postMessage(JSON.stringify({token:readerTestToken,kind:'chooseFile'}));")
            instrumentation.waitForIdleSync()
            delay(100)
            assertNull("Read-only events must not create a draft", vault.pendingDraft)
            assertEquals(original, vault.state.value.entries.single { it.optString("id") == note.getString("id") }.toString())
            assertEquals("true", evaluate(first, "document.querySelector('.tiptap strong').textContent === 'FULL_ORIGINAL_BODY'"))
            // Exercise the installed native request filter, independently of CSP blocking the request earlier.
            instrumentation.runOnMainSync {
                for (url in listOf("https://example.invalid/leak", "file:///etc/hosts", "content://fixture/private", "pvnote://wrong-token/${attachment.getString("id")}")) {
                    val response = first.webViewClient.shouldInterceptRequest(first, request(url))
                    assertNotNull("Unapproved resource must be denied: $url", response)
                    assertEquals(403, response!!.statusCode)
                }
                assertTrue(first.settings.blockNetworkLoads)
                assertFalse(first.settings.allowFileAccess)
                assertFalse(first.settings.allowContentAccess)
                assertFalse(first.settings.domStorageEnabled)
            }
            scenario.moveToState(Lifecycle.State.CREATED)
            noReader()
            assertTrue("Backgrounding the reader must hide content without changing the vault's lock policy", vault.state.value.unlocked)
            instrumentation.runOnMainSync { assertEquals(View.INVISIBLE, first.visibility) }
            scenario.moveToState(Lifecycle.State.RESUMED)
            val resumed = readyReader()
            assertNotSame("Resuming creates a fresh session, never reuses the destroyed WebView", first, resumed)
            vault.lock()
            noReader()
            instrumentation.runOnMainSync { assertEquals(View.INVISIBLE, resumed.visibility) }
            vault.authenticate("synthetic read-only rich fixture", false)
            val unlocked = readyReader()
            assertNotSame(resumed, unlocked)
            assertEquals(original, vault.state.value.entries.single { it.optString("id") == note.getString("id") }.toString())
            assertNull(vault.pendingDraft)
        } finally {
            scenario?.close()
            vault.close()
            directory.deleteRecursively()
            activityDirectory.deleteRecursively()
        }
    }

    private fun text(value: String, bold: Boolean = false) = JSONObject().put("type", "text").put("text", value).apply {
        if (bold) put("marks", JSONArray().put(JSONObject().put("type", "bold")))
    }

    private fun request(value: String) = object : WebResourceRequest {
        override fun getUrl(): Uri = Uri.parse(value)
        override fun isForMainFrame() = false
        override fun isRedirect() = false
        override fun hasGesture() = false
        override fun getMethod() = "GET"
        override fun getRequestHeaders(): MutableMap<String, String> = mutableMapOf()
    }
}
