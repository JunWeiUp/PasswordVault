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
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Info
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
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

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RichNoteEditor(original: JSONObject, vault: VaultRepository, t: (String, String) -> String, close: () -> Unit) {
    val context = LocalContext.current; val scope = rememberCoroutineScope()
    var title by remember { mutableStateOf(original.optString("title")) }
    var session by remember { mutableStateOf<AndroidNoteSession?>(null) }
    var message by remember { mutableStateOf("") }; var saving by remember { mutableStateOf(false) }; var discard by remember { mutableStateOf(false) }
    var exportData by remember { mutableStateOf<ByteArray?>(null) }
    var info by remember { mutableStateOf(false) }
    var dirty by remember { mutableStateOf(false) }
    LaunchedEffect(session) {
        if (session == null) return@LaunchedEffect
        while (isActive) {
            dirty = title != original.optString("title") || vault.pendingDraft?.let { it != original.toString() } == true
            delay(350)
        }
    }
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
    BackHandler { if (!saving) discard = true }
    Dialog(onDismissRequest = { if (!saving) discard = true }, properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnClickOutside = false, dismissOnBackPress = false, decorFitsSystemWindows = false)) {
        EditorDialogBars()
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                TopAppBar(
                    expandedHeight = 55.dp,
                    colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                    navigationIcon = { IconButton(enabled = !saving, onClick = { discard = true }) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, t("返回", "Back")) } },
                    title = { Text(if (dirty) t("未保存的修改", "Unsaved changes") else t("没有修改", "No changes"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) },
                    actions = {
                        IconButton(onClick = { info = true }) { Icon(Icons.Outlined.Info, t("笔记信息", "Note information")) }
                        Button(enabled = vault.canEdit(original) && !saving && title.isNotBlank(), modifier = Modifier.padding(end = 12.dp), contentPadding = PaddingValues(horizontal = 18.dp, vertical = 8.dp), onClick = { scope.launch {
                            saving = true
                            message = ""
                            try {
                                val text = session?.capture(false)?.await() ?: error("Cannot capture")
                                val draft = JSONObject(text).put("title", title)
                                if (vault.save(draft)) { vault.captureRichDraft = null; vault.discardDraft(); session?.capture(true); close() }
                                else message = t("保存未完成，草稿已保留", "Save incomplete; draft retained")
                            } catch (_: Exception) { message = t("保存未完成，草稿已保留", "Save incomplete; draft retained") } finally { saving = false }
                        } }) { Text(if (saving) t("保存中…", "Saving…") else t("保存", "Save")) }
                    },
                )
            },
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).imePadding(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                BasicTextField(
                    value = title,
                    onValueChange = { title = it; dirty = true; session?.setTitle(it) },
                    enabled = vault.canEdit(original) && !saving,
                    textStyle = MaterialTheme.typography.headlineSmall.copy(fontSize = 24.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onBackground),
                    cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                    modifier = Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 4.dp),
                    decorationBox = { field -> Box { if (title.isEmpty()) Text(t("标题", "Title"), style = MaterialTheme.typography.headlineSmall, color = MaterialTheme.colorScheme.onSurfaceVariant); field() } },
                )
                Text(listOf(noteDate(original), original.optString("category")).filter { it.isNotBlank() }.joinToString(" · "), Modifier.padding(horizontal = 18.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (message.isNotEmpty()) Text(message, Modifier.padding(horizontal = 18.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
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
    if (info) AlertDialog(onDismissRequest = { info = false }, title = { Text(t("笔记信息", "Note information")) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title.ifBlank { t("无标题", "Untitled") }, style = MaterialTheme.typography.titleMedium)
            Text(t("修改时间 · ", "Modified · ") + noteDate(original))
            if (original.optString("category").isNotBlank()) Text(t("分类 · ", "Category · ") + original.optString("category"))
            Text(t("图文原件与附件保存在加密库中。", "The original rich document and attachments are stored in the encrypted vault."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }, confirmButton = { TextButton(onClick = { info = false }) { Text(t("完成", "Done")) } })

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
    val view: WebView = PrivateInputWebView(context)
    init {
        val dark = when (vault.state.value.settings.optString("theme")) {
            "dark" -> true
            "light" -> false
            else -> context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK == android.content.res.Configuration.UI_MODE_NIGHT_YES
        }
        val hostCss = """
            :root{color-scheme:${if (dark) "dark" else "light"};font-size:14px;--panel:${if (dark) "#1c2027" else "#fff"};--line:${if (dark) "#2d333e" else "#e4e8ef"};--accent:${if (dark) "#7aa2ff" else "#3265db"}}
            html,body{overflow:auto!important;min-height:100%;background:${if (dark) "#121419" else "#f3f5f8"};color:${if (dark) "#e8ebf1" else "#242a35"}}
            #editor{padding:8px 18px 120px}.ProseMirror{font-size:14px;line-height:24px;min-height:calc(100vh - 78px)}
            .editor-tools{position:fixed;left:0;right:0;bottom:0;z-index:30;display:flex;flex-direction:column;background:var(--panel);border-top:1px solid var(--line)}
            .toolbar{order:10;display:flex;flex-direction:row;flex-wrap:nowrap;align-items:center;gap:8px;min-height:52px;margin:0;padding:6px 8px;border:0;border-radius:0;background:var(--panel);overflow-x:auto;overflow-y:hidden;white-space:nowrap}
            .toolbar-row{display:contents}.toolbar-row+.toolbar-row{border:0;padding:0}.toolbar-label{display:none}
            .toolbar .toolgroup{display:contents}.toolbar .color-tools{display:inline-flex;order:30}.toolbar>*,.toolbar-row>*{flex-shrink:0}
            .toolbar button,.toolbar select,.toolbar summary{min-height:36px;white-space:nowrap;border:0;background:transparent;color:inherit;padding:4px 6px;font-size:12px}.toolbar .toolmenu button{white-space:normal}
            .toolbar button{order:50}
            .toolbar button[aria-pressed="true"]{color:var(--accent);background:#3265db18}
            .toolbar select{order:0;width:64px;padding:4px 0}.toolbar details{order:40}.toolbar .color-picker{order:30}
            .toolbar .toolgroup>button[data-action],.toolbar-row>button[data-action]{min-width:32px;font-size:0}
            .toolbar .toolgroup>button[data-action]::before,.toolbar-row>button[data-action]::before{font-size:17px;line-height:24px;content:attr(title)}
            .toolbar [data-action="toggleBold"]{order:1}.toolbar [data-action="toggleBold"]::before{content:"B"!important}
            .toolbar [data-action="toggleItalic"]{order:2}.toolbar [data-action="toggleItalic"]::before{content:"I"!important}
            .toolbar [data-action="toggleBulletList"]{order:3}.toolbar [data-action="toggleBulletList"]::before{content:"☷"!important}
            .toolbar [data-action="toggleOrderedList"]{order:4}.toolbar [data-action="toggleOrderedList"]::before{content:"≡"!important}
            .toolbar [data-action="toggleTaskList"]{order:5}.toolbar [data-action="toggleTaskList"]::before{content:"☑"!important}
            .toolbar [data-action="link"]{order:6}.toolbar [data-action="link"]::before{content:"↗"!important}
            .toolbar [data-action="image"]{order:7}.toolbar [data-action="image"]::before{content:"▧"!important}
            .toolbar [data-action="attachment"]{order:8}.toolbar [data-action="attachment"]::before{content:"＋"!important}
            .toolbar [data-action="insertTable"]{order:9}.toolbar [data-action="insertTable"]::before{content:"▦"!important}
            .toolbar [data-action="find"]{order:31}.toolbar [data-action="find"]::before{content:"⌕"!important}
            .toolbar [data-action="toggleUnderline"]{order:20}.toolbar [data-action="toggleUnderline"]::before{content:"U"!important}
            .toolbar [data-action="toggleStrike"]{order:21}.toolbar [data-action="toggleStrike"]::before{content:"S"!important}
            .toolbar [data-action="undo"]{order:22}.toolbar [data-action="undo"]::before{content:"↶"!important}
            .toolbar [data-action="redo"]{order:23}.toolbar [data-action="redo"]::before{content:"↷"!important}
            .toolbar .toolmenu,.toolbar .color-panel{position:fixed!important;top:auto!important;bottom:60px;left:8px!important;right:auto!important;max-width:calc(100vw - 16px);max-height:50vh;overflow:auto;white-space:normal}
            .context,.findbar,.notice{margin:0;padding:6px 10px;max-height:30vh;overflow:auto}.stats{display:none}
            input,select,textarea{font-size:16px}
        """.trimIndent()
        val html = context.assets.open("NoteEditor.html").bufferedReader().use { it.readText() }.replace("</style>", "$hostCss</style>")
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
