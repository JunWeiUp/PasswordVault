package com.securepass.vault

import android.annotation.SuppressLint
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.*
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.util.UUID

@Composable
internal fun RichNoteEditor(original: JSONObject, vault: VaultRepository, t: (String, String) -> String, close: () -> Unit) {
    val context = LocalContext.current; val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf(original.optString("title")) }
    var session by remember { mutableStateOf<AndroidNoteSession?>(null) }
    var message by remember { mutableStateOf("") }; var saving by remember { mutableStateOf(false) }; var discard by remember { mutableStateOf(false) }
    var exportData by remember { mutableStateOf<ByteArray?>(null) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val data = exportData; exportData = null
        if (uri != null && data != null) scope.launch { try { withContext(Dispatchers.IO) { context.contentResolver.openOutputStream(uri)?.use { it.write(data) } ?: error("Cannot export") } } catch (_: Exception) { message = t("导出失败，原件已保留", "Export failed; original retained") } }
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val active = session
        if (uri == null) active?.uploadError() else if (active != null) scope.launch {
            try {
                var name = "Attachment"; context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) name = it.getString(0) }
                val bytes = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { input ->
                    val output = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
                    while (true) { val count = input.read(buffer); if (count < 0) break; require(output.size() + count <= 25 * 1024 * 1024); output.write(buffer, 0, count) }; output.toByteArray()
                } ?: error("Cannot read") }
                active.importChosen(bytes, name, context.contentResolver.getType(uri) ?: "application/octet-stream")
            } catch (_: Exception) { active.uploadError() }
        }
    }
    BackHandler { discard = true }
    Dialog(onDismissRequest = { discard = true }, properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnClickOutside = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().imePadding().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(enabled = !saving, onClick = { discard = true }) { Text(t("取消", "Cancel")) }
                    Button(enabled = vault.canEdit(original) && !saving && title.isNotBlank(), onClick = { scope.launch {
                        saving = true
                        try {
                            val text = session?.capture(false)?.await() ?: error("Cannot capture")
                            val draft = JSONObject(text).put("title", title)
                            if (vault.save(draft)) { vault.captureRichDraft = null; vault.discardDraft(); session?.capture(true); close() }
                        } catch (_: Exception) { message = t("保存未完成，草稿已保留", "Save incomplete; draft retained") } finally { saving = false }
                    } }) { Text(t("保存", "Save")) }
                }
                OutlinedTextField(title, { title = it; session?.setTitle(it) }, label = { Text(t("标题", "Title")) }, enabled = vault.canEdit(original), modifier = Modifier.fillMaxWidth())
                if (message.isNotEmpty()) Text(message, color = MaterialTheme.colorScheme.error)
                AndroidView(modifier = Modifier.fillMaxWidth().weight(1f), factory = { ctx ->
                    runCatching { AndroidNoteSession(ctx, original, vault, scope, t,
                        choose = { picker.launch(arrayOf("*/*")) },
                        export = { bytes, name -> exportData = bytes; export.launch(name.substringAfterLast('/').substringAfterLast('\\')) },
                        failure = { message = t("编辑器操作未完成，最近确认的草稿已保留", "Editor operation incomplete; last confirmed draft retained") }
                    ).also { session = it; if (vault.canEdit(original)) { vault.pendingDraft = original.toString(); vault.captureRichDraft = { it.capture(true) } } }.view }.getOrElse {
                        android.widget.TextView(ctx).apply { text = t("系统 WebView 不可用，无法打开图文编辑器。原资料未修改。", "System WebView is unavailable. The rich editor cannot open; original data is unchanged.") }
                    }
                })
            }
        }
    }
    if (discard) AlertDialog(onDismissRequest = { discard = false }, title = { Text(t("放弃未保存的修改？", "Discard unsaved changes?")) }, confirmButton = {
        TextButton(onClick = { vault.captureRichDraft = null; vault.discardDraft(); session?.discard(); close() }) { Text(t("放弃修改", "Discard changes")) }
    }, dismissButton = { TextButton(onClick = { discard = false }) { Text(t("继续编辑", "Keep editing")) } })
    DisposableEffect(Unit) { onDispose { session?.capture(true) } }
}

@SuppressLint("SetJavaScriptEnabled")
internal class AndroidNoteSession(
    context: android.content.Context,
    original: JSONObject,
    private val vault: VaultRepository,
    private val scope: CoroutineScope,
    private val t: (String, String) -> String,
    private val choose: () -> Unit,
    private val export: (ByteArray, String) -> Unit,
    private val failure: () -> Unit,
) {
    val token: String = UUID.randomUUID().toString()
    private val handler = Handler(Looper.getMainLooper())
    private var item = JSONObject(original.toString())
    private val noteId = item.getString("id")
    @Volatile private var closing = false
    private var ready = false
    private var destroyed = false
    private var revision = 0
    private var request: String? = null
    private var closeTask: CompletableDeferred<String?>? = null
    private val captures = mutableMapOf<String, CompletableDeferred<String?>>()
    private val cancelled = mutableSetOf<String>()
    private data class Upload(val name: String, val mime: String, val size: Int, val bytes: java.io.ByteArrayOutputStream = java.io.ByteArrayOutputStream())
    private val uploads = mutableMapOf<String, Upload>()
    val view = WebView(context)
    init {
        val html = context.assets.open("NoteEditor.html").bufferedReader().use { it.readText() }.replace("</style>", "html,body{overflow:auto!important;min-height:100%}#editor{padding:8px}input,select,textarea{font-size:16px}</style>")
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
        CookieManager.getInstance().setAcceptThirdPartyCookies(view, false)
        view.addJavascriptInterface(object {
            @JavascriptInterface fun postMessage(raw: String) {
                if (raw.length > 24 * 1024 * 1024) return
                handler.post { receive(raw) }
            }
        }, "VaultNoteBridge")
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
            override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse {
                val url = request?.url
                if (!closing && request?.isForMainFrame == true && url.toString() == "https://vault-note.invalid/editor") {
                    return WebResourceResponse("text/html", "utf-8", 200, "OK", mapOf("Cache-Control" to "no-store"), ByteArrayInputStream(html.toByteArray(Charsets.UTF_8)))
                }
                if (!closing && vault.state.value.unlocked && url?.scheme == "pvnote" && url.host == token && url.query == null && url.pathSegments.size == 1) {
                    return try {
                        val bytes = runBlocking(Dispatchers.IO) { vault.readNoteAttachment(noteId, url.pathSegments[0]) }
                        if (closing || !vault.state.value.unlocked) denied() else WebResourceResponse("image/png", null, ByteArrayInputStream(bytes))
                    } catch (_: Exception) { denied() }
                }
                return denied()
            }
            override fun onPageFinished(view: WebView?, url: String?) {
                if (closing || ready) return
                ready = true
                val options = JSONObject().put("token", token).put("sequence", 0).put("expectedRevision", 0).put("format", item.optString("noteFormat", "markdown")).put("source", source()).put("editable", vault.canEdit(item)).put("editing", true).put("chinese", t("是", "yes") == "是")
                js("window.webkit={messageHandlers:{noteEditor:{postMessage:function(value){VaultNoteBridge.postMessage(JSON.stringify(value))}}}};window.pvEditor.configure($options)")
            }
            override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean { failure(); return true }
        }
        view.loadUrl("https://vault-note.invalid/editor")
    }
    private fun denied() = WebResourceResponse("text/plain", "utf-8", 403, "Forbidden", emptyMap(), ByteArrayInputStream(ByteArray(0)))
    private fun js(script: String) { view.evaluateJavascript(script, null) }
    private fun source(): String = if (item.optString("noteFormat") == "rich-v1") JSONObject().put("format", "rich-v1").put("document", item.getJSONObject("noteDocument")).put("text", item.optString("note")).toString() else item.optString("note")
    private fun acceptSource(source: String) {
        val payload = runCatching { JSONObject(source) }.getOrNull()
        if (payload?.optString("format") == "rich-v1" && payload.optJSONObject("document")?.optString("type") == "doc") {
            if (item.optString("noteFormat") != "rich-v1" && !item.has("noteOriginal")) item.put("noteOriginal", JSONObject().put("format", item.optString("noteFormat")).put("source", item.optString("note")))
            item.put("noteFormat", "rich-v1").put("noteDocument", payload.getJSONObject("document")).put("note", payload.optString("text"))
        } else item.put("note", source)
    }
    fun setTitle(title: String) { item.put("title", title); if (!closing && vault.state.value.unlocked) vault.pendingDraft = item.toString() }
    private fun receive(raw: String) {
        val body = runCatching { JSONObject(raw) }.getOrNull() ?: return
        if (body.optString("token") != token) return
        val kind = body.optString("kind")
        if (kind == "captureResult") {
            val capture = captures.remove(body.optString("request")) ?: return
            if (body.optString("source").length > 16 * 1024 * 1024) { capture.complete(null); return }
            acceptSource(body.optString("source")); capture.complete(item.toString()); if (closing) clear(); return
        }
        if (closing || !vault.state.value.unlocked || !ready) return
        when (kind) {
            "change" -> if (vault.canEdit(item) && body.optInt("revision", -1) >= revision) { revision = body.getInt("revision"); acceptSource(body.getString("source")); vault.pendingDraft = item.toString(); vault.activity() }
            "chooseFile" -> { request = body.optString("request"); if (vault.state.value.entries.any { it.optString("id") == noteId }) choose() else uploadError("请先保存笔记再添加附件 / Save this note before attaching files") }
            "uploadStart" -> if (vault.canEdit(item) && body.optInt("size", -1) in 0..25*1024*1024 && uploads.size < 4) uploads[body.getString("request")] = Upload(body.optString("name"), body.optString("mime", "application/octet-stream"), body.getInt("size"))
            "uploadChunk" -> { val id = body.optString("request"); val upload = uploads[id] ?: return; val encoded = body.optString("data"); if (encoded.length > 300_000) return; val bytes = runCatching { Base64.decode(encoded, Base64.DEFAULT) }.getOrNull() ?: return; if (upload.bytes.size() + bytes.size <= upload.size) upload.bytes.write(bytes) }
            "uploadFinish" -> { val id = body.optString("request"); val upload = uploads.remove(id) ?: return; if (upload.bytes.size() == upload.size) scope.launch { importData(id, upload.bytes.toByteArray(), upload.name, upload.mime) } }
            "cancelUpload" -> { val id = body.optString("request"); cancelled.add(id); uploads.remove(id) }
            "discardAttachment" -> scope.launch { runCatching { vault.discardNoteAttachment(noteId, body.getString("id")) } }
            "saveAttachment" -> scope.launch { try { val bytes = vault.readNoteAttachment(noteId, body.getString("id")); if (!closing && vault.state.value.unlocked) export(bytes, body.optString("name", "Attachment")) } catch (_: Exception) { failure() } }
            "exportMarkdown" -> export(body.optString("markdown").toByteArray(), "Note.md")
            "wheel" -> { val delta = body.optDouble("deltaY"); if (delta.isFinite()) view.scrollBy(0, delta.coerceIn(-10000.0, 10000.0).toInt()) }
            "failure" -> failure()
        }
    }
    suspend fun importChosen(bytes: ByteArray, name: String, mime: String) { request?.let { importData(it, bytes, name, mime) } }
    private suspend fun importData(id: String, bytes: ByteArray, name: String, mime: String) {
        if (closing || !vault.state.value.unlocked || !vault.canEdit(item) || id in cancelled) return
        try {
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            if (mime.startsWith("image/")) android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val actualMime = if (mime.startsWith("image/") && (mime !in listOf("image/png", "image/jpeg", "image/gif", "image/webp") || bounds.outWidth <= 0)) "application/octet-stream" else mime
            val meta = vault.importNoteAttachment(noteId, name, actualMime, bytes)
            if (closing || !vault.state.value.unlocked || id in cancelled) { runCatching { vault.discardNoteAttachment(noteId, meta.getString("id")) }; return }
            js("window.pvEditor.attachment(${JSONObject.quote(id)},$meta)")
        } catch (_: Exception) { uploadError(id = id) }
    }
    fun uploadError(message: String = "附件导入失败，请重试 / Attachment import failed; retry", id: String? = request) { if (!closing && id != null) js("window.pvEditor.uploadError(${JSONObject.quote(id)},${JSONObject.quote(message)})") }
    fun capture(close: Boolean): Deferred<String?> {
        closeTask?.let { return it }
        val result = CompletableDeferred<String?>()
        if (close) { closing = true; closeTask = result }
        handler.post {
            if (close) { view.visibility = android.view.View.INVISIBLE; uploads.clear() }
            if (!ready) { result.complete(item.toString()); if (close) clear(); return@post }
            val id = UUID.randomUUID().toString(); captures[id] = result
            js("window.pvEditor.snapshot($close).then(function(value){VaultNoteBridge.postMessage(JSON.stringify({kind:'captureResult',token:${JSONObject.quote(token)},request:${JSONObject.quote(id)},source:value.source}))})")
            handler.postDelayed({ if (captures.remove(id) != null) { result.complete(item.toString()); failure(); if (close) clear() } }, 3000)
        }
        return result
    }
    fun discard() { closing = true; closeTask = CompletableDeferred(item.toString()); clear() }
    private fun clear() { if (destroyed) return; destroyed = true; ready = false; view.removeJavascriptInterface("VaultNoteBridge"); view.stopLoading(); view.loadUrl("about:blank"); view.destroy() }
}
