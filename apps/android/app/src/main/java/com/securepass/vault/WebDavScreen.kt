package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
fun WebDavScreen(vault: VaultRepository, state: VaultState, t: (String, String) -> String) {
    val config = state.settings.optJSONObject("webdav") ?: JSONObject()
    var url by remember { mutableStateOf(config.optString("url")) }
    var username by remember { mutableStateOf(config.optString("username")) }
    var password by remember { mutableStateOf(config.optString("password")) }
    var folder by remember { mutableStateOf(config.optString("folder", "PasswordVault")) }
    var secret by remember { mutableStateOf("") }
    var files by remember { mutableStateOf(emptyList<RemoteBackup>()) }
    var target by remember { mutableStateOf<RemoteBackup?>(null) }
    var savingConfig by remember { mutableStateOf(false) }
    var listing by remember { mutableStateOf(false) }
    var transferring by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val hasUrl = url.trim().isNotEmpty()
    fun run(isList: Boolean, action: suspend (WebDav) -> String) {
        if ((isList && listing) || transferring) return
        if (isList) listing = true else transferring = true
        message = null
        scope.launch {
            try {
                val client = WebDav(url, username, password, folder)
                try {
                    message = action(client)
                } finally {
                    client.close()
                }
            } catch (_: Exception) {
                message =
                    t(
                        "操作未完成，请检查连接、服务器权限和文件密码。原资料保留。",
                        "Check connection, server permissions and file password. Existing data is preserved.",
                    )
            } finally {
                if (isList) listing = false else transferring = false
            }
        }
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("WebDAV", style = MaterialTheme.typography.headlineSmall)
        Input("https://…", url, { url = it })
        Input(t("用户名", "Username"), username, { username = it })
        Input(t("服务器密码", "Server password"), password, { password = it }, secret = true)
        Input(t("文件夹", "Folder"), folder, { folder = it })
        Text(
            t(
                "连接设置加密保存，远程连接使用 HTTPS。",
                "Connection settings are encrypted; remote connections use HTTPS.",
            ),
            style = MaterialTheme.typography.bodySmall,
        )
        OutlinedButton(
            enabled = !savingConfig && !transferring && hasUrl,
            onClick = {
                savingConfig = true
                scope.launch {
                    try {
                        if (
                            vault.mutate(
                                "settings",
                                JSONObject()
                                    .put(
                                        "settings",
                                        JSONObject()
                                            .put(
                                                "webdav",
                                                JSONObject()
                                                    .put("url", url)
                                                    .put("username", username)
                                                    .put("password", password)
                                                    .put("folder", folder),
                                            ),
                                    ),
                            )
                        )
                            message = t("设置已保存", "Settings saved")
                    } finally {
                        savingConfig = false
                    }
                }
            },
        ) {
            Text(if (savingConfig) t("保存中…", "Saving…") else t("保存设置", "Save settings"))
        }
        Button(
            enabled = !listing && !transferring && hasUrl,
            onClick = {
                run(true) { client ->
                    files = withContext(Dispatchers.IO) { client.list() }
                    "${files.size} ${t("份备份", "backups")}"
                }
            },
        ) {
            Text(if (listing) t("读取列表中…", "Refreshing…") else t("连接并刷新", "Connect & refresh"))
        }
        if (!hasUrl) {
            Text(
                t("门控原因：请先填写 HTTPS 服务器地址后再保存或连接。", "Required: enter an HTTPS server URL before saving or connecting."),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Input(t("新备份文件密码", "Password for new backup"), secret, { secret = it }, secret = true)
        Button(
            enabled = !transferring && hasUrl && secret.length >= 10,
            onClick = {
                run(false) { client ->
                    val content =
                        vault
                            .command("export", JSONObject().put("password", secret))
                            .getString("content")
                    withContext(Dispatchers.IO) { client.upload(content.toByteArray()) }
                    files = withContext(Dispatchers.IO) { client.list() }
                    secret = ""
                    t("加密备份已上传", "Encrypted backup uploaded")
                }
            },
        ) {
            Text(if (transferring) t("传输中…", "Transferring…") else t("创建加密备份", "Create encrypted backup"))
        }
        if (secret.length < 10) {
            Text(
                t("门控原因：需输入至少 10 位独立备份文件密码后启用上传。", "Required: enter a backup file password of at least 10 characters."),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (listing || transferring) LinearProgressIndicator(Modifier.fillMaxWidth())
        message?.let { Text(it) }
        files.forEach { file ->
            OutlinedCard(
                onClick = {
                    target = file
                    secret = ""
                },
                enabled = !transferring,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(file.name)
                    Text(
                        "${file.modified?.let { DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(it)) } ?: t("时间未知", "Unknown date")} · ${file.size?.let { android.text.format.Formatter.formatShortFileSize(androidx.compose.ui.platform.LocalContext.current, it) } ?: t("大小未知", "Unknown size")}",
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(t("合并恢复…", "Merge & restore…"), color = MaterialTheme.colorScheme.primary)
                }
            }
        }
    }
    target?.let { file ->
        AlertDialog(
            onDismissRequest = {
                target = null
                secret = ""
            },
            title = { Text(t("合并恢复", "Merge backup")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(file.name)
                    Text(
                        t(
                            "旧版加密 JSON 使用当时的主密码，其他条目会保留。",
                            "Use the original password for legacy encrypted JSON. Other entries are retained.",
                        )
                    )
                    Input(
                        t("这份文件的密码", "This file’s password"),
                        secret,
                        { secret = it },
                        secret = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val inputPassword = secret
                        target = null
                        run(false) { client ->
                            val content =
                                withContext(Dispatchers.IO) {
                                    client.download(file).toString(Charsets.UTF_8)
                                }
                            if (
                                !vault.mutate(
                                    "import",
                                    JSONObject()
                                        .put("content", content)
                                        .put("password", inputPassword)
                                        .put("kind", "json"),
                                )
                            )
                                error("Import failed")
                            secret = ""
                            t("备份已合并", "Backup merged")
                        }
                    }
                ) {
                    Text(t("合并", "Merge"))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        target = null
                        secret = ""
                    }
                ) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
    }
}
