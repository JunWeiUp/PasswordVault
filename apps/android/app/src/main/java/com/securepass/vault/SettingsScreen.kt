package com.securepass.vault

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
fun SettingsScreen(
    vault: VaultRepository,
    state: VaultState,
    t: (String, String) -> String,
    language: () -> Unit,
    trash: () -> Unit,
    webdav: () -> Unit,
    sharing: () -> Unit,
) {
    val context = LocalContext.current
    val biometric = remember { BiometricVault(context as androidx.fragment.app.FragmentActivity) }
    val scope = rememberCoroutineScope()
    var category by remember { mutableStateOf("") }
    var currentPassword by remember { mutableStateOf("") }
    var nextPassword by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var passwordChange by remember { mutableStateOf(false) }
    var audit by remember { mutableStateOf<List<JSONObject>?>(null) }
    var backupPassword by remember { mutableStateOf("") }
    var backup by remember { mutableStateOf<ByteArray?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var importFormat by remember { mutableStateOf("auto") }
    var plainExport by remember { mutableStateOf<String?>(null) }
    var exportWasPlain by remember { mutableStateOf(false) }
    val importFormats =
        linkedMapOf(
            "auto" to t("自动识别 JSON / CSV / 原生备份", "Auto detect JSON / CSV / native backup"),
            "encrypted-csv" to t("旧版加密 CSV", "Legacy encrypted CSV"),
            "lastpass" to "LastPass CSV",
            "bitwarden" to "Bitwarden CSV",
            "1password" to "1Password CSV",
            "chrome" to "Chrome CSV",
        )
    val export =
        rememberLauncherForActivityResult(
            ActivityResultContracts.CreateDocument("application/octet-stream")
        ) { uri ->
            vault.systemFileFlow = false
            val bytes = backup
            backup = null
            if (uri != null && bytes != null)
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                                ?: error("No output")
                        }
                        backupPassword = ""
                        message =
                            if (exportWasPlain) t("文件已导出", "File exported")
                            else t("加密备份已保存", "Encrypted backup saved")
                    } catch (_: Exception) {
                        vault.report()
                    } finally {
                        bytes.fill(0)
                    }
                }
        }
    val restore =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            vault.systemFileFlow = false
            if (uri != null) {
                val selectedFormat = importFormat
                val selectedPassword = backupPassword
                scope.launch {
                    working = true
                    try {
                        val content =
                            withContext(Dispatchers.IO) {
                                context.contentResolver.openInputStream(uri)?.use {
                                    val data = it.readNBytesCompat(64 * 1024 * 1024 + 1)
                                    require(data.size <= 64 * 1024 * 1024)
                                    data.toString(Charsets.UTF_8)
                                } ?: error("No input")
                            }
                        val converted =
                            if (
                                selectedFormat in
                                    listOf("lastpass", "bitwarden", "1password", "chrome")
                            )
                                parseMigrationCsv(content, selectedFormat)
                            else content
                        // JSON readers also recognize encrypted native and legacy envelopes.
                        if (
                            vault.mutate(
                                "import",
                                JSONObject()
                                    .put("content", converted)
                                    .put("password", selectedPassword)
                                    .put(
                                        "kind",
                                        if (selectedFormat == "encrypted-csv") "encrypted-csv"
                                        else if (
                                            converted.trimStart().startsWith("{") ||
                                                converted.trimStart().startsWith("[")
                                        )
                                            "json"
                                        else "csv",
                                    ),
                            )
                        ) {
                            backupPassword = ""
                            message = t("备份已合并", "Backup merged")
                        }
                    } catch (_: Exception) {
                        vault.report()
                    } finally {
                        working = false
                    }
                }
            }
        }
    if (plainExport != null)
        AlertDialog(
            onDismissRequest = { plainExport = null },
            title = { Text(t("导出未加密文件？", "Export an unencrypted file?")) },
            text = {
                Text(
                    t(
                        "文件中的账号和密码可直接读取。仅在迁移到其他工具时使用；CSV 不包含完整历史和共享信息。",
                        "Accounts and passwords will be readable. Use for migration; CSV omits full history and sharing metadata.",
                    )
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val kind = plainExport ?: return@TextButton
                        plainExport = null
                        working = true
                        scope.launch {
                            try {
                                backup =
                                    vault
                                        .command("export-plain", JSONObject().put("kind", kind))
                                        .getString("content")
                                        .toByteArray()
                                exportWasPlain = true
                                vault.systemFileFlow = true
                                export.launch("PasswordVault.$kind")
                            } catch (_: Exception) {
                                vault.report()
                            } finally {
                                working = false
                            }
                        }
                    }
                ) {
                    Text(t("导出", "Export"))
                }
            },
            dismissButton = {
                TextButton(onClick = { plainExport = null }) { Text(t("取消", "Cancel")) }
            },
        )
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(t("设置", "Settings"), style = MaterialTheme.typography.headlineMedium)
        LegacySection {
            Text(t("安全", "Security"), style = MaterialTheme.typography.titleLarge)
            Text(
                t(
                    "切到后台立即锁定；禁止截图，复制内容 30 秒后清除。",
                    "Locks in the background, blocks screenshots, and clears copied content after 30 seconds.",
                )
            )
            BiometricSettings(biometric, vault, t)
            Text(t("空闲锁定（分钟）", "Idle lock (minutes)"))
            Row {
                listOf(1, 5, 15, 60).forEach { minutes ->
                    FilterChip(
                        selected = state.settings.optInt("autoLockMinutes", 60) == minutes,
                        onClick = {
                            scope.launch {
                                vault.mutate(
                                    "settings",
                                    JSONObject()
                                        .put(
                                            "settings",
                                            JSONObject().put("autoLockMinutes", minutes),
                                        ),
                                )
                            }
                        },
                        label = { Text("$minutes") },
                        modifier = Modifier.padding(end = 8.dp),
                    )
                }
            }
            if (android.os.Build.VERSION.SDK_INT >= 26)
                OutlinedButton(
                    onClick = {
                        context.startActivity(
                            android.content
                                .Intent(
                                    android.provider.Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE
                                )
                                .setData(android.net.Uri.parse("package:" + context.packageName))
                        )
                    }
                ) {
                    Text(t("启用系统自动填充", "Enable system Autofill"))
                }
            else Text(t("Android 8 以下使用手动复制填写。", "Use manual copy on Android versions below 8."))
            OutlinedButton(onClick = { passwordChange = true }) {
                Text(t("修改主密码", "Change master password"))
            }
        }
        LegacySection {
            Text(t("笔记分类", "Note categories"), style = MaterialTheme.typography.titleLarge)
            val categories = state.settings.optJSONArray("noteCategories")
            if (categories != null)
                for (index in 0 until categories.length()) {
                    val name = categories.optString(index)
                    Row {
                        Text(name, Modifier.weight(1f))
                        TextButton(
                            onClick = {
                                scope.launch {
                                    vault.mutate(
                                        "category-remove",
                                        JSONObject()
                                            .put("name", name)
                                            .put("time", java.time.Instant.now().toString()),
                                    )
                                }
                            }
                        ) {
                            Text(t("移除分类，保留笔记", "Remove category; keep notes"))
                        }
                    }
                }
            Input(t("新分类", "New category"), category, { category = it })
            TextButton(
                enabled = category.isNotBlank(),
                onClick = {
                    scope.launch {
                        if (vault.mutate("category-add", JSONObject().put("name", category.trim())))
                            category = ""
                    }
                },
            ) {
                Text(t("添加分类", "Add category"))
            }
        }
        LegacySection {
            Text(t("备份与恢复", "Backups & restore"), style = MaterialTheme.typography.titleLarge)
            Input(
                t("文件密码（旧备份使用原密码）", "File password (original for old backups)"),
                backupPassword,
                { backupPassword = it },
                secret = true,
            )
            Button(
                enabled = !working && backupPassword.length >= 10,
                onClick = {
                    scope.launch {
                        working = true
                        try {
                            backup =
                                vault
                                    .command("export", JSONObject().put("password", backupPassword))
                                    .getString("content")
                                    .toByteArray()
                            exportWasPlain = false
                            vault.systemFileFlow = true
                            export.launch("PasswordVault.pvbackup")
                        } catch (_: Exception) {
                            vault.report()
                        } finally {
                            working = false
                        }
                    }
                },
            ) {
                Text(t("导出加密备份", "Export encrypted backup"))
            }
            OutlinedButton(
                enabled = !working && backupPassword.length >= 10,
                onClick = {
                    scope.launch {
                        working = true
                        try {
                            backup =
                                vault
                                    .command(
                                        "export-csv-backup",
                                        JSONObject().put("password", backupPassword),
                                    )
                                    .getString("content")
                                    .toByteArray()
                            exportWasPlain = false
                            vault.systemFileFlow = true
                            export.launch("PasswordVault.csv.pvbackup")
                        } catch (_: Exception) {
                            vault.report()
                        } finally {
                            working = false
                        }
                    }
                },
            ) {
                Text(t("导出加密 CSV", "Export encrypted CSV"))
            }
            Text(
                t(
                    "加密 CSV 使用新版备份加密；旧版 .csv.enc 可导入。完整迁移请优先使用上方加密备份。",
                    "Encrypted CSV uses the native backup encryption; old .csv.enc files can be imported. Prefer the full encrypted backup for complete migration.",
                ),
                style = MaterialTheme.typography.bodySmall,
            )
            ChoiceEditor(
                t("导入格式", "Import format"),
                importFormats[importFormat].orEmpty(),
                importFormats.values.toList(),
                t,
                allowCustom = false,
            ) { label ->
                importFormat =
                    importFormats.entries.firstOrNull { it.value == label }?.key ?: "auto"
            }
            OutlinedButton(
                enabled = !working,
                onClick = {
                    vault.systemFileFlow = true
                    restore.launch(
                        arrayOf("application/json", "application/octet-stream", "text/*")
                    )
                },
            ) {
                Text(t("选择文件并合并…", "Choose file and merge…"))
            }
            Text(
                t(
                    "支持旧版加密 JSON、原生备份和 CSV。恢复不会删除其他条目。",
                    "Supports legacy encrypted JSON, native backups and CSV. Restore keeps other entries.",
                ),
                style = MaterialTheme.typography.bodySmall,
            )
            Row {
                TextButton(enabled = !working, onClick = { plainExport = "json" }) {
                    Text(t("导出明文 JSON…", "Export plain JSON…"))
                }
                TextButton(enabled = !working, onClick = { plainExport = "csv" }) {
                    Text(t("导出明文 CSV…", "Export plain CSV…"))
                }
            }
            message?.let { Text(it) }
            OutlinedButton(onClick = sharing) { Text(t("共享资料库", "Shared vaults")) }
            OutlinedButton(onClick = webdav) { Text("WebDAV") }
            OutlinedButton(onClick = trash) { Text(t("回收站", "Trash")) }
            HorizontalDivider()
            OutlinedButton(
                onClick = {
                    scope.launch {
                        try {
                            audit = vault.audit().objects()
                        } catch (_: Exception) {
                            vault.report()
                        }
                    }
                }
            ) {
                Text(t("检查密码健康", "Check password health"))
            }
        }
        LegacySection {
            Text(t("密码生成器", "Password generator"), style = MaterialTheme.typography.titleLarge)
            PasswordGeneratorControls(vault, t)
            HorizontalDivider()
        }
        LegacySection {
            Text(t("外观", "Appearance"), style = MaterialTheme.typography.titleLarge)
            Row {
                listOf("system", "light", "dark").forEach { theme ->
                    FilterChip(
                        selected = state.settings.optString("theme", "system") == theme,
                        onClick = {
                            scope.launch {
                                vault.mutate(
                                    "settings",
                                    JSONObject().put("settings", JSONObject().put("theme", theme)),
                                )
                            }
                        },
                        label = {
                            Text(
                                when (theme) {
                                    "system" -> t("系统", "System")
                                    "light" -> t("浅色", "Light")
                                    else -> t("深色", "Dark")
                                }
                            )
                        },
                        modifier = Modifier.padding(end = 8.dp),
                    )
                }
            }
            TextButton(onClick = language) { Text("简体中文 / English") }
            Text(
                "PasswordVault ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
    if (passwordChange)
        AlertDialog(
            onDismissRequest = {
                if (!working) {
                    passwordChange = false
                    currentPassword = ""
                    nextPassword = ""
                    confirmation = ""
                }
            },
            title = { Text(t("修改主密码", "Change master password")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Input(
                        t("当前主密码", "Current password"),
                        currentPassword,
                        { currentPassword = it },
                        secret = true,
                    )
                    Input(
                        t("新主密码", "New password"),
                        nextPassword,
                        { nextPassword = it },
                        secret = true,
                    )
                    Input(
                        t("确认新密码", "Confirm new password"),
                        confirmation,
                        { confirmation = it },
                        secret = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled =
                        !working &&
                            currentPassword.isNotEmpty() &&
                            nextPassword.isNotEmpty() &&
                            nextPassword == confirmation,
                    onClick = {
                        working = true
                        scope.launch {
                            try {
                                vault.command(
                                    "change-password",
                                    JSONObject()
                                        .put("currentPassword", currentPassword)
                                        .put("newPassword", nextPassword),
                                )
                                biometric.disable()
                                currentPassword = ""
                                nextPassword = ""
                                confirmation = ""
                                passwordChange = false
                                message =
                                    t(
                                        "主密码已更新，请重新启用生物识别",
                                        "Password updated; re-enable biometric unlock",
                                    )
                            } catch (_: Exception) {
                                vault.report()
                            } finally {
                                working = false
                            }
                        }
                    },
                ) {
                    Text(t("更改", "Change"))
                }
            },
            dismissButton = {
                TextButton(
                    enabled = !working,
                    onClick = {
                        passwordChange = false
                        currentPassword = ""
                        nextPassword = ""
                        confirmation = ""
                    },
                ) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
    audit?.let { results ->
        AlertDialog(
            onDismissRequest = { audit = null },
            title = { Text(t("密码健康", "Password health")) },
            text = {
                Column(
                    Modifier.verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    if (results.isEmpty()) Text(t("未发现风险条目", "No issues found"))
                    results.forEach { item ->
                        Text(item.optString("title"))
                        Text(
                            listOfNotNull(
                                    if (item.optBoolean("weak")) t("较弱", "Weak") else null,
                                    if (item.optBoolean("reused")) t("重复使用", "Reused") else null,
                                    if (item.optBoolean("expired")) t("已过期", "Expired") else null,
                                )
                                .joinToString(" · "),
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            },
            confirmButton = { TextButton(onClick = { audit = null }) { Text(t("完成", "Done")) } },
        )
    }
}

private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(8192)
    while (out.size() < limit) {
        val n = read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (n < 0) break
        out.write(buffer, 0, n)
    }
    return out.toByteArray()
}
