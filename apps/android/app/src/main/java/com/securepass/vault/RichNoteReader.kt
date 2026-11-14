package com.securepass.vault

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.UUID

/** A separate, non-mutating host for the shared editor's existing read-only mode. */
@Composable
internal fun RichNoteReader(item: JSONObject, vault: VaultRepository, t: (String, String) -> String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val background = MaterialTheme.colorScheme.background
    val foreground = MaterialTheme.colorScheme.onBackground
    val dark = background.luminance() < 0.5f
    val owner = LocalLifecycleOwner.current
    var generation by remember { mutableIntStateOf(0) }
    var failed by remember(item.toString(), dark, generation) { mutableStateOf(false) }
    val reader = remember(item.toString(), dark, generation) {
        runCatching { ReadOnlyNoteSession(context, item, vault, t, background.toArgb(), foreground.toArgb(), dark) { failed = true } }.getOrNull()
    }
    DisposableEffect(reader, owner) {
        // ON_STOP can pause Compose's frame clock before recomposition: remove decrypted content now.
        var stopped = false
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP || event == Lifecycle.Event.ON_DESTROY) {
                stopped = true
                reader?.close()
            } else if (event == Lifecycle.Event.ON_START && stopped) {
                stopped = false
                generation++
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer); reader?.close() }
    }
    Box(modifier) {
        if (reader == null || failed) Text(
            t("无法显示图文原件。原资料未修改，可稍后重试。", "Could not display the rich document. The original is unchanged; try again later."),
            Modifier.padding(vertical = 12.dp), color = MaterialTheme.colorScheme.error,
        ) else key(reader) { AndroidView(factory = { reader.view }, modifier = Modifier.fillMaxSize()) }
    }
    LaunchedEffect(failed) { if (failed) reader?.close() }
}

@SuppressLint("SetJavaScriptEnabled")
private class ReadOnlyNoteSession(
    context: android.content.Context,
    item: JSONObject,
    private val vault: VaultRepository,
    t: (String, String) -> String,
    background: Int,
    foreground: Int,
    dark: Boolean,
    private val failure: () -> Unit,
) {
    private val token = UUID.randomUUID().toString()
    private val noteId = item.getString("id")
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    private var configured = false
    private val source = JSONObject().put("format", "rich-v1")
        .put("document", item.getJSONObject("noteDocument"))
        .put("text", item.optString("note")).toString()
    // Retain the packaged CSP and sanitizer. Only reader presentation is overridden.
    private val html = context.assets.open("NoteEditor.html").bufferedReader().use { it.readText() }.replace(
        "</style>",
        ":root{color-scheme:${if (dark) "dark" else "light"};color:${cssColor(foreground)};font-size:14px}html,body{overflow:auto!important;min-height:100%;background:${cssColor(background)}}#editor{padding:4px 0 24px}.editor-tools,.stats,.bubble,.context{display:none!important}</style>",
    )
    val view = WebView(context)

    init {
        view.setBackgroundColor(background)
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = false
        view.settings.cacheMode = WebSettings.LOAD_NO_CACHE
        @Suppress("DEPRECATION")
        view.settings.saveFormData = false
        view.settings.allowFileAccess = false
        view.settings.allowContentAccess = false
        view.settings.blockNetworkLoads = true
        view.settings.setSupportMultipleWindows(false)
        view.settings.mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        view.importantForAutofill = android.view.View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        view.isLongClickable = false
        view.setOnLongClickListener { true }
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        view.addJavascriptInterface(object {
            @JavascriptInterface fun postMessage(raw: String) {
                if (closed || raw.length > 16 * 1024) return
                handler.post {
                    if (closed || !vault.state.value.unlocked) return@post
                    val body = runCatching { JSONObject(raw) }.getOrNull() ?: return@post
                    if (body.optString("token") != token) return@post
                    // Read-only host: no mutation, upload, export, capture or draft messages are accepted.
                    when (body.optString("kind")) {
                        "failure" -> failure()
                        "wheel" -> {
                            val delta = body.optDouble("deltaY")
                            if (delta.isFinite()) view.scrollBy(0, delta.coerceIn(-10000.0, 10000.0).toInt())
                        }
                    }
                }
            }
        }, "VaultNoteBridge")
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse {
                if (closed || !vault.state.value.unlocked) return denied()
                val url = request?.url
                if (request?.isForMainFrame == true && url.toString() == "https://vault-note.invalid/reader") {
                    return WebResourceResponse("text/html", "utf-8", 200, "OK", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
                }
                if (url?.scheme == "pvnote" && url.host == token && url.query == null && url.fragment == null && url.pathSegments.size == 1) {
                    return try {
                        val bytes = runBlocking(Dispatchers.IO) { vault.readNoteAttachment(noteId, url.pathSegments[0]) }
                        if (closed || !vault.state.value.unlocked) denied()
                        else WebResourceResponse("image/png", null, ByteArrayInputStream(bytes))
                    } catch (_: Exception) { denied() }
                }
                return denied()
            }
            override fun onPageFinished(view: WebView?, url: String?) {
                if (closed || configured || !vault.state.value.unlocked || url != "https://vault-note.invalid/reader") return
                configured = true
                val options = JSONObject().put("token", token).put("sequence", 0).put("expectedRevision", 0)
                    .put("format", "rich-v1").put("source", source).put("editable", false).put("editing", false)
                    .put("chinese", t("是", "yes") == "是")
                this@ReadOnlyNoteSession.view.evaluateJavascript(
                    "window.webkit={messageHandlers:{noteEditor:{postMessage:function(value){VaultNoteBridge.postMessage(JSON.stringify(value))}}}};window.pvEditor.configure($options)", null,
                )
            }
            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                failure()
                return true
            }
        }
        view.loadUrl("https://vault-note.invalid/reader")
    }

    fun close() {
        if (closed) return
        closed = true
        view.visibility = android.view.View.INVISIBLE
        (view.parent as? android.view.ViewGroup)?.removeView(view)
        handler.removeCallbacksAndMessages(null)
        view.removeJavascriptInterface("VaultNoteBridge")
        view.stopLoading()
        view.loadUrl("about:blank")
        view.destroy()
    }

    private fun denied() = WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    private fun cssColor(color: Int) = "#%06x".format(color and 0xffffff)
}
