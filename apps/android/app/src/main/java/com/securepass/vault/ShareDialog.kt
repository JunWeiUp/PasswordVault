package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@Composable
internal fun ShareDialog(vault: VaultRepository, id: String, t: (String, String) -> String, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    val labels = mapOf("title" to t("标题", "Title"), "username" to t("用户名", "Username"), "password" to t("密码", "Password"), "url" to t("网址", "Website"), "note" to t("备注 / 笔记摘要", "Notes / text summary"), "secret" to t("验证码密钥", "Authenticator secret"), "mnemonic" to t("助记词", "Recovery phrase"), "privateKey" to t("私钥", "Private key"), "address" to t("地址", "Address"), "network" to t("网络", "Network"), "category" to t("分类", "Category"), "tags" to t("标签", "Tags"), "card" to t("银行卡资料（含安全码）", "Card details (including security code)"), "identity" to t("身份资料", "Identity details"), "customFields" to t("全部自定义字段（含隐藏值）", "All custom fields (including concealed values)"))
    var managed by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var revokeID by remember { mutableStateOf<String?>(null) }
    var endpoint by remember { mutableStateOf(vault.state.value.settings.optString("shareServiceURL")) }
    var token by remember { mutableStateOf(vault.state.value.settings.optString("shareServiceToken")) }
    var fields by remember { mutableStateOf<List<String>>(emptyList()) }
    var attachments by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var selected by remember { mutableStateOf(setOf("title", "username", "password", "url", "note")) }
    var files by remember { mutableStateOf(setOf<String>()) }
    var email by remember { mutableStateOf("") }
    var restrictEmail by remember { mutableStateOf(false) }
    var emailSupported by remember { mutableStateOf(false) }
    var expiry by remember { mutableIntStateOf(86400) }
    var expiryExpanded by remember { mutableStateOf(false) }
    var configExpanded by remember { mutableStateOf(endpoint.isBlank()) }
    var fieldsExpanded by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var link by remember { mutableStateOf("") }
    var shareID by remember { mutableStateOf("") }
    var createdClient by remember { mutableStateOf<ShareServiceClient?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val run: (suspend () -> Unit) -> Unit = { action -> if (!busy) { busy = true; message = null; scope.launch { try { action() } catch (_: Exception) { message = t("操作未完成，请检查服务、权限、网络和附件大小。", "Operation incomplete. Check service configuration, permissions, network and attachment size.") } finally { busy = false } } } }
    LaunchedEffect(id) { run {
        val options = vault.command("share-options", JSONObject().put("id", id))
        val values = options.getJSONArray("fields"); fields = (0 until values.length()).map { values.getString(it) }
        val values2 = options.getJSONArray("attachments"); attachments = (0 until values2.length()).map { values2.getJSONObject(it) }
    } }
    DisposableEffect(Unit) { onDispose { token = ""; link = ""; createdClient = null } }
    VaultActionSheet(t("临时分享", "Temporary share"),
        t("生成端到端加密的只读链接；对方无需安装应用。密钥只在链接片段中，服务端看不到内容。", "Create an end-to-end encrypted read-only link. Recipients need no app. The key stays in the link fragment; the server cannot read the contents."),
        { if (!busy) close() }) {
            Text(t("分享所选字段的加密副本。后续修改不更新链接；撤销不能收回已下载内容。", "Share an encrypted copy of selected fields. Later edits do not update the link; revocation cannot retract downloaded copies."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(enabled = !busy, onClick = { configExpanded = !configExpanded }) { Text(t("分享服务配置", "Share service configuration")) }
            if (configExpanded) LegacySection {
            Input(t("分享服务地址（HTTPS）", "Share service URL (HTTPS)"), endpoint, { endpoint = it }, enabled = !busy)
            Input(t("服务访问令牌", "Service access token"), token, { token = it }, secret = true, enabled = !busy)
            TextButton(enabled = !busy, onClick = { run {
                val client = ShareServiceClient(endpoint, token)
                val capabilities = client.capabilities(); client.list()
                check(vault.mutate("settings", JSONObject().put("settings", JSONObject().put("shareServiceURL", endpoint).put("shareServiceToken", token))))
                emailSupported = capabilities.optBoolean("emailVerification")
                message = if (emailSupported) t("配置已保存，可验证邮箱。", "Saved; email verification available.") else t("配置已保存，邮件发送尚未配置。", "Saved; SMTP is not configured.")
            } }) { Text(t("检查并保存配置", "Check and save configuration")) }
            }
            LegacySection {
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text(t("有效期", "Expires in"), Modifier.weight(1f))
                    val durations = listOf(3600 to t("1 小时", "1 hour"), 86400 to t("1 天", "1 day"), 604800 to t("7 天", "7 days"), 2592000 to t("30 天", "30 days"))
                    Box {
                        TextButton(enabled = !busy, onClick = { expiryExpanded = true }) { Text(durations.first { it.first == expiry }.second) }
                        DropdownMenu(expiryExpanded, { expiryExpanded = false }) {
                            durations.forEach { (value, title) -> DropdownMenuItem(text = { Text(title) }, onClick = { expiry = value; expiryExpanded = false }) }
                        }
                    }
                }
                HorizontalDivider()
                Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(t("只能打开一次", "One-time access"))
                        Text(t("当前分享服务尚不支持", "Unavailable with the current share service"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = false, onCheckedChange = null, enabled = false)
                }
                if ("password" in fields) {
                    HorizontalDivider()
                    Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(t("包含密码", "Include password"))
                            Text(t("可在下方调整其他分享字段", "Adjust other shared fields below"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Switch("password" in selected, { selected = if (it) selected + "password" else selected - "password" }, enabled = !busy)
                    }
                }
            }
            TextButton(enabled = !busy, onClick = { fieldsExpanded = !fieldsExpanded }) { Text(t("包含的字段与附件", "Included fields and attachments")) }
            if (fieldsExpanded) LegacySection {
                fields.forEach { field -> Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) { Checkbox(field in selected, { selected = if (it) selected + field else selected - field }, enabled = !busy); Text(labels[field] ?: field, Modifier.weight(1f)) } }
                attachments.forEach { file -> val fileID = file.getString("id"); Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) { Checkbox(fileID in files, { files = if (it) files + fileID else files - fileID }, enabled = !busy); Text(file.optString("name"), Modifier.weight(1f)) } }
            }
            Text(t("不包含密码历史或 Passkey 私钥；笔记为文字摘要，附件需单独勾选。", "Excludes password history and Passkey private keys. Notes are text summaries; choose attachments separately."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row { Checkbox(restrictEmail, { restrictEmail = it }, enabled = !busy && emailSupported); Text(t("仅指定邮箱", "Recipient email only")) }
            if (restrictEmail) Input(t("接收邮箱", "Recipient email"), email, { email = it }, enabled = !busy)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(enabled = !busy, onClick = close) { Text(t("取消", "Cancel")) }
            Button(enabled = !busy && fields.any { it in selected } && endpoint.isNotBlank() && (!restrictEmail || email.isNotBlank()), onClick = { run {
                val client = ShareServiceClient(endpoint, token)
                val envelope = vault.command("share-seal", JSONObject().put("id", id).put("fields", JSONArray(fields.filter { it in selected })).put("attachmentIds", JSONArray(files.toList())))
                val result = client.create(envelope, expiry, if (restrictEmail) email else null)
                check(vault.state.value.unlocked)
                link = result; shareID = envelope.getString("id"); createdClient = client
            } }) { Text(t("创建链接", "Create link")) }
            }
            Text(t("创建链接需要联网并收到真实服务回执。", "Creating a link requires a connection and a service receipt."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (link.isNotEmpty()) {
                Text(t("链接含解密密钥，关闭后无法从服务器重新取回。", "The link includes the key, which cannot be retrieved from the server after closing."))
                TextButton(onClick = { vault.copy(link) }) { Text(t("复制完整链接", "Copy complete link")) }
                TextButton(enabled = !busy, onClick = { run { createdClient?.revoke(shareID); link = ""; createdClient = null; message = t("已撤销", "Revoked") } }) { Text(t("撤销链接", "Revoke link")) }
            }
            TextButton(enabled = !busy, onClick = { run {
                val rows = ShareServiceClient(endpoint, token).list().getJSONArray("shares")
                managed = (0 until rows.length()).map { rows.getJSONObject(it) }
            } }) { Text(t("管理未到期的链接", "Manage active links")) }
            managed.forEach { share ->
                Text(share.getString("id"))
                Text(java.text.DateFormat.getDateTimeInstance().format(java.util.Date(share.getLong("expiry"))))
                TextButton(enabled = !busy, onClick = { revokeID = share.getString("id") }) { Text(t("撤销", "Revoke")) }
            }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            message?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
    revokeID?.let { sid -> AlertDialog(onDismissRequest = { revokeID = null }, title = { Text(t("撤销链接？", "Revoke link?")) }, text = { Text(t("已下载的副本无法收回。", "Downloaded copies cannot be retracted.")) }, confirmButton = { TextButton(onClick = { revokeID = null; run { val client = ShareServiceClient(endpoint, token); client.revoke(sid); managed = managed.filter { it.optString("id") != sid }; if (shareID == sid) link = "" } }) { Text(t("撤销", "Revoke")) } }, dismissButton = { TextButton(onClick = { revokeID = null }) { Text(t("取消", "Cancel")) } }) }
}
