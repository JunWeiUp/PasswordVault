package com.securepass.vault

import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.URL
import javax.net.ssl.HttpsURLConnection

@Composable
internal fun StructuredFieldsEditor(item: JSONObject, update: (JSONObject) -> Unit, t: (String, String) -> String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pendingAttachment by remember { mutableStateOf<JSONObject?>(null) }
    var exportError by remember { mutableStateOf("") }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val attachment = pendingAttachment; pendingAttachment = null
        if (uri != null && attachment != null) scope.launch {
            try { withContext(Dispatchers.IO) { val bytes = Base64.decode(attachment.getString("data"), Base64.DEFAULT); context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) } ?: error("Cannot export") } }
            catch (_: Exception) { exportError = t("无法导出附件", "Could not export attachment") }
        }
    }
    val attachments = item.optJSONObject("importSource")?.optJSONArray("attachments") ?: JSONArray()
    for (index in 0 until attachments.length()) {
        val attachment = attachments.getJSONObject(index)
        TextButton(onClick = { pendingAttachment = attachment; export.launch(attachment.optString("name", "attachment").substringAfterLast('/').substringAfterLast('\\')) }) { Text("${t("下载附件", "Export attachment")}: ${attachment.optString("name")}") }
    }
    if (exportError.isNotEmpty()) Text(exportError, color = MaterialTheme.colorScheme.error)
    val group = when (item.optString("type")) { "creditCard" -> "card"; "identity" -> "identity"; else -> null }
    val card = listOf("cardholder" to "持卡人", "number" to "卡号", "expiryMonth" to "到期月", "expiryYear" to "到期年", "securityCode" to "安全码", "brand" to "卡组织")
    val identity = listOf("firstName" to "名", "lastName" to "姓", "email" to "邮箱", "phone" to "电话", "address1" to "地址", "address2" to "地址补充", "city" to "城市", "region" to "省 / 州", "postalCode" to "邮编", "country" to "国家", "company" to "公司")
    if (group != null) for ((key, label) in if (group == "card") card else identity) {
        OutlinedTextField(value = item.optJSONObject(group)?.optString(key).orEmpty(), onValueChange = { value ->
            val next = JSONObject(item.toString()); val fields = next.optJSONObject(group) ?: JSONObject(); fields.put(key, value); next.put(group, fields); update(next)
        }, label = { Text(t(label, key)) }, visualTransformation = if (key in listOf("number", "securityCode")) PasswordVisualTransformation() else VisualTransformation.None, modifier = Modifier.fillMaxWidth())
    }
    Text(t("自定义字段", "Custom fields"), style = MaterialTheme.typography.titleMedium)
    val fields = item.optJSONArray("customFields") ?: JSONArray()
    for (index in 0 until fields.length()) {
        val field = fields.getJSONObject(index)
        fun change(key: String, value: String) { val next = JSONObject(item.toString()); val values = next.getJSONArray("customFields"); values.getJSONObject(index).put(key, value); update(next) }
        OutlinedTextField(field.optString("label"), { change("label", it) }, label = { Text(t("字段名称", "Field label")) }, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(field.optString("group"), { change("group", it) }, label = { Text(t("分组", "Group")) }, modifier = Modifier.fillMaxWidth())
        Row { Checkbox(field.optString("kind") == "concealed", { change("kind", if (it) "concealed" else "text") }); Text(t("隐藏内容", "Concealed")) }
        OutlinedTextField(field.optString("value"), { change("value", it) }, label = { Text(t("内容", "Value")) }, visualTransformation = if (field.optString("kind") == "concealed") PasswordVisualTransformation() else VisualTransformation.None, modifier = Modifier.fillMaxWidth())
        TextButton(onClick = { val next = JSONObject(item.toString()); next.getJSONArray("customFields").remove(index); update(next) }) { Text(t("移除字段", "Remove field")) }
    }
    TextButton(enabled = fields.length() < 256, onClick = { val next = JSONObject(item.toString()); val values = next.optJSONArray("customFields") ?: JSONArray(); values.put(JSONObject().put("id", java.util.UUID.randomUUID().toString()).put("label", "").put("kind", "concealed").put("value", "")); next.put("customFields", values); update(next) }) { Text(t("添加字段", "Add field")) }
}

@Composable
internal fun ImportReviewPanel(vault: VaultRepository, t: (String, String) -> String) {
    val context = LocalContext.current; val scope = rememberCoroutineScope()
    var source by remember { mutableStateOf("") }; var format by remember { mutableStateOf("csv") }; var previewText by remember { mutableStateOf("") }
    var checkedMappingText by remember { mutableStateOf("{}") }
    var mappingText by remember { mutableStateOf("{}") }; var choicesText by remember { mutableStateOf("{}") }; var busy by remember { mutableStateOf(false) }; var message by remember { mutableStateOf("") }
    suspend fun inspect(data: String = source, kind: String = format) { val submitted = mappingText; busy = true; try { previewText = vault.command("import-preview", JSONObject().put("format", kind).put("data", data).put("mapping", JSONObject(submitted))).toString(); checkedMappingText = submitted; choicesText = "{}"; message = "" } catch (_: Exception) { previewText = ""; message = t("预检失败；资料库未更改", "Preview failed; vault unchanged") } finally { busy = false } }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) scope.launch {
        busy = true
        try {
            val data = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { input -> val bytes = input.readBytesLimited(64 * 1024 * 1024); Base64.encodeToString(bytes, Base64.NO_WRAP) } ?: error("Cannot open file") }
            var name = ""; context.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) name = it.getString(0) }
            source = data; format = if (name.endsWith(".1pux", true)) "1pux" else "csv"; mappingText = "{}"; inspect(data, format)
        } catch (_: Exception) { message = t("无法读取文件，原文件未修改", "Could not read file; source unchanged") } finally { busy = false }
    } }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(t("导入 CSV / 1Password .1pux", "Import CSV / 1Password .1pux"), style = MaterialTheme.typography.titleMedium)
        Text(t("重复条目默认跳过，不覆盖同名记录；原文件不会删除。", "Duplicates are skipped by default; existing records and source files are retained."))
        Button(enabled = !busy, onClick = { picker.launch(arrayOf("*/*")) }) { Text(t("选择文件", "Choose file")) }
        if (message.isNotEmpty()) Text(message)
        val preview = previewText.takeIf { it.isNotEmpty() }?.let(::JSONObject)
        if (preview != null) {
            if (format == "csv") {
                Text(t("字段映射：输入列名；留空自动匹配", "Mapping: enter a column name; blank uses automatic mapping"))
                for (key in listOf("title", "username", "password", "url", "notes")) OutlinedTextField(JSONObject(mappingText).optString(key), { value -> val mapping = JSONObject(mappingText); if (value.isEmpty()) mapping.remove(key) else mapping.put(key, value); mappingText = mapping.toString() }, label = { Text(key) }, enabled = !busy)
                Text(preview.optJSONArray("columns")?.join(", ").orEmpty())
                TextButton(enabled = !busy, onClick = { scope.launch { inspect() } }) { Text(t("重新预检", "Recheck")) }
            }
            val rows = preview.optJSONArray("rows") ?: JSONArray()
            for (i in 0 until rows.length()) {
                val row = rows.getJSONObject(i); val key = row.getInt("index").toString(); val choices = JSONObject(choicesText); val duplicate = row.getJSONArray("duplicateIds").length() > 0
                Row { Checkbox(if (choices.has(key)) choices.optString(key) == "add" else !duplicate, enabled = !busy, onCheckedChange = { choices.put(key, if (it) "add" else "skip"); choicesText = choices.toString() }); Text(row.getJSONObject("item").optString("title") + if (duplicate) t("（重复或同名）", " (duplicate or same title)") else "") }
                val warnings = row.optJSONArray("warnings") ?: JSONArray(); for (j in 0 until warnings.length()) Text(warnings.getString(j))
            }
            val failures = preview.optJSONArray("failures") ?: JSONArray(); for (i in 0 until failures.length()) Text(failures.getJSONObject(i).optString("reason"), color = MaterialTheme.colorScheme.error)
            Button(enabled = !busy && rows.length() > 0 && checkedMappingText == mappingText, onClick = { scope.launch { busy = true; try { val result = vault.command("import-commit", JSONObject().put("format", format).put("data", source).put("mapping", JSONObject(mappingText)).put("choices", JSONObject(choicesText))); vault.refresh(); message = "${t("已导入", "Imported")}: ${result.optInt("added")}; ${t("跳过", "Skipped")}: ${result.optInt("skipped")}"; source = ""; previewText = "" } catch (_: Exception) { message = t("导入失败；原有数据已保留", "Import failed; existing data retained") } finally { busy = false } } }) { Text(t("确认导入", "Confirm import")) }
        }
    }
}

private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
    val result = java.io.ByteArrayOutputStream(); val buffer = ByteArray(8192)
    while (true) { val count = read(buffer); if (count < 0) break; require(result.size() + count <= limit); result.write(buffer, 0, count) }
    return result.toByteArray()
}

@Composable
internal fun SecurityCenterPanel(vault: VaultRepository, items: List<JSONObject>, t: (String, String) -> String, openItem: (String) -> Unit) {
    val scope = rememberCoroutineScope(); val context = LocalContext.current
    var reportText by remember { mutableStateOf("{}") }; var enabled by remember { mutableStateOf(false) }; var busy by remember { mutableStateOf(false) }; var message by remember { mutableStateOf("") }
    var showLicenses by remember { mutableStateOf(false) }
    var results by remember { mutableStateOf<Map<String, String>>(emptyMap()) }; var job by remember { mutableStateOf<Job?>(null) }
    suspend fun refresh() { try { reportText = vault.command("security-audit").toString() } catch (_: Exception) { message = t("本地检查未完成", "Local check incomplete") } }
    val catalogPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try { val text = withContext(Dispatchers.IO) { context.contentResolver.openInputStream(uri)?.use { String(it.readBytesLimited(8 * 1024 * 1024), Charsets.UTF_8) } ?: error("Cannot read") }; vault.command("security-catalog", JSONObject().put("catalog", JSONObject(text))); refresh() }
            catch (_: Exception) { message = t("目录导入失败，已保留原目录", "Catalog import failed; previous catalog retained") }
        }
    }
    LaunchedEffect(Unit) { refresh() }
    DisposableEffect(Unit) { onDispose { job?.cancel() } }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(t("安全中心", "Security center"), style = MaterialTheme.typography.titleMedium)
        Text(t("网站目录覆盖有限；未列入的网站未检查。建议不代表账号已启用验证。", "Site coverage is limited; unlisted sites are not checked. Suggestions do not verify account configuration."))
        val report = JSONObject(reportText); Text("${t("目录更新", "Catalog updated")}: ${report.optString("catalogUpdatedAt")}")
        TextButton(onClick = { catalogPicker.launch(arrayOf("application/json")) }) { Text(t("导入更新目录", "Import updated catalog")) }
        TextButton(onClick = { scope.launch { refresh() } }) { Text(t("重新检查", "Recheck")) }
        TextButton(onClick = { showLicenses = !showLicenses }) { Text(t("数据来源与许可", "Data sources and licenses")) }
        if (showLicenses) {
            Text(report.optString("catalogLicense"))
            val sources = report.optJSONArray("catalogSources") ?: JSONArray()
            for (index in 0 until sources.length()) Text(sources.getJSONObject(index).optString("url"))
            Text(report.optString("catalogLicenseText"), style = MaterialTheme.typography.bodySmall)
        }
        val findings = report.optJSONArray("findings") ?: JSONArray()
        for (i in 0 until findings.length()) {
            val finding = findings.getJSONObject(i)
            TextButton(onClick = { openItem(finding.optString("id")) }) { Text("${finding.optString("title", finding.optString("id"))} · ${securityFindingTitle(finding.optString("kind"), t)}") }
            val detail = securityFindingDetails(finding, t)
            if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodyMedium)
            val link = finding.optString("source").ifEmpty { finding.optJSONObject("incident")?.optString("source").orEmpty() }
            if (link.startsWith("https://")) TextButton(onClick = { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(link))) }) { Text(t("查看依据", "View source")) }
            TextButton(onClick = { scope.launch { try { vault.command("security-ignore", JSONObject().put("key", finding.getString("key")).put("ignored", !finding.optBoolean("ignored"))); refresh() } catch (_: Exception) { message = t("无法保存设置", "Could not save setting") } } }) { Text(if (finding.optBoolean("ignored")) t("恢复提醒", "Restore finding") else t("忽略此项", "Ignore finding")) }
        }
        Row { Checkbox(enabled, { enabled = it; if (!it) { job?.cancel(); results = emptyMap() } }); Text(t("允许本次联网检查", "Allow network check for this session")) }
        Text(t("仅向 Have I Been Pwned 发送 SHA-1 前 5 位；不发送密码、完整哈希、账号或站点。未检查和失败不表示安全。", "Only 5 SHA-1 characters go to Have I Been Pwned; no passwords, full hashes, accounts or sites. Unchecked and failed do not mean safe."))
        Button(enabled = enabled && !busy, onClick = { job = scope.launch {
            busy = true; results = emptyMap()
            try { for (item in items.filter { it.optString("type") == "password" && !it.optBoolean("isDeleted") }) {
                ensureActive(); var result = t("无密码可检查", "No password to check")
                try {
                    val passwords = mutableSetOf(item.optString("password")); val accounts = item.optJSONArray("accounts") ?: JSONArray(); for (i in 0 until accounts.length()) passwords.add(accounts.getJSONObject(i).optString("password")); passwords.remove("")
                    var count = 0L
                    for (password in passwords) {
                        ensureActive(); val parts = vault.command("breach-request", JSONObject().put("password", password)); val prefix = parts.getString("prefix"); require(prefix.matches(Regex("[A-F0-9]{5}")))
                        val response = withContext(Dispatchers.IO) {
                            val connection = URL("https://api.pwnedpasswords.com/range/$prefix").openConnection() as HttpsURLConnection
                            try { connection.instanceFollowRedirects = false; connection.useCaches = false; connection.connectTimeout = 15000; connection.readTimeout = 15000; connection.setRequestProperty("Add-Padding", "true"); require(connection.responseCode == 200); connection.inputStream.use { String(it.readBytesLimited(4 * 1024 * 1024), Charsets.UTF_8) } } finally { connection.disconnect() }
                        }
                        count += vault.command("breach-response", JSONObject().put("suffix", parts.getString("suffix")).put("response", response)).getLong("count")
                    }
                    if (passwords.isNotEmpty()) result = if (count > 0) t("发现泄露记录，请更换密码", "Exposed password found; change it") else t("本次查询未发现记录", "Not found in this query")
                } catch (error: CancellationException) { throw error } catch (_: Exception) { result = t("检查未完成，请重试", "Check incomplete; retry") }
                ensureActive(); results = results + (item.getString("id") to result)
            } } finally { busy = false }
        } }) { Text(t("检查 / 重新检查", "Check / recheck")) }
        for (item in items.filter { it.optString("type") == "password" && !it.optBoolean("isDeleted") }) Text("${item.optString("title")}: ${results[item.optString("id")] ?: t("未检查", "Not checked")}")
        if (message.isNotEmpty()) Text(message, color = MaterialTheme.colorScheme.error)
    }
}

private fun securityFindingTitle(kind: String, t: (String, String) -> String): String = when (kind) {
    "passwordHealth" -> t("密码需要检查", "Password needs attention")
    "twoFactorAvailable" -> t("可启用双重验证", "Two-factor authentication available")
    "passkeyAvailable" -> t("支持通行密钥", "Passkey available")
    "siteIncident" -> t("网站安全事件", "Website security incident")
    "duplicateEntry" -> t("重复条目", "Duplicate entry")
    else -> t("其他安全提醒", "Other security finding")
}
private fun securityFindingDetails(finding: JSONObject, t: (String, String) -> String): String {
    if (finding.optString("kind") != "passwordHealth") return ""
    return listOf(
        if (finding.optBoolean("weak")) t("密码较弱", "Weak password") else "",
        if (finding.optBoolean("reused")) t("密码重复使用", "Reused password") else "",
        if (finding.optBoolean("expired")) t("密码已超过设置的有效期", "Password exceeds its configured age") else "",
    ).filter(String::isNotEmpty).joinToString(" · ")
}
