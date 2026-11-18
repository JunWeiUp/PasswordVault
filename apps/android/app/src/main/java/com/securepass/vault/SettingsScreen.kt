package com.securepass.vault

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(
    vault: VaultRepository,
    state: VaultState,
    t: (String, String) -> String,
    language: () -> Unit,
    trash: () -> Unit,
    webdav: () -> Unit,
    relay: () -> Unit,
    openEntry: (String) -> Unit = {},
    openNavigation: (() -> Unit)? = null,
    onSubpageChanged: (Boolean) -> Unit = {},
    initialPage: String = "home",
    devices: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val biometric = remember { BiometricVault(context as androidx.fragment.app.FragmentActivity) }
    val scope = rememberCoroutineScope()
    val relayState by vault.relay.state.collectAsStateWithLifecycle()
    var page by remember { mutableStateOf(initialPage) }
    val notifySubpageChanged by rememberUpdatedState(onSubpageChanged)
    LaunchedEffect(page) { notifySubpageChanged(page != "home") }
    DisposableEffect(Unit) {
        onDispose { notifySubpageChanged(false) }
    }
    val pageTitles = mapOf(
        "home" to t("设置", "Settings"),
        "general" to t("通用", "General"),
        "security" to t("安全", "Security"),
        "autofill" to t("自动填充与通行密钥", "Autofill & Passkeys"),
        "backup" to t("备份与导入", "Backups & import"),
        "recovery" to t("恢复密钥", "Recovery key"),
        "about" to t("关于", "About"),
        "generator" to t("密码生成器", "Password generator"),
        "health" to t("密码健康", "Password health"),
    )
    BackHandler(enabled = page != "home") { page = "home" }
    var capabilityPanel by remember { mutableStateOf<String?>(null) }
    if (capabilityPanel != null) androidx.compose.ui.window.Dialog(onDismissRequest = { capabilityPanel = null }, properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) { Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            TextButton(onClick = { capabilityPanel = null }) { Text(t("关闭", "Close")) }
            if (capabilityPanel == "import") ImportReviewPanel(vault, t)
            else SecurityCenterPanel(vault, state.entries, t) { id -> capabilityPanel = null; openEntry(id) }
        } }
    }
    var category by remember { mutableStateOf("") }
    var currentPassword by remember { mutableStateOf("") }
    var nextPassword by remember { mutableStateOf("") }
    var confirmation by remember { mutableStateOf("") }
    var passwordChange by remember { mutableStateOf(false) }
    var audit by remember { mutableStateOf<List<JSONObject>?>(null) }
    var auditRevision by remember { mutableIntStateOf(0) }
    var auditFailed by remember { mutableStateOf(false) }
    LaunchedEffect(page, auditRevision) {
        if (page == "health") {
            audit = null
            auditFailed = false
            try { audit = vault.audit().objects() }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { auditFailed = true; vault.report() }
        }
    }
    var recoveryEnabled by remember { mutableStateOf<Boolean?>(null) }
    var backupPassword by remember { mutableStateOf("") }
    var backup by remember { mutableStateOf<ByteArray?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var working by remember { mutableStateOf(false) }
    var recovery by remember { mutableStateOf(false) }
    if (recovery) RecoveryDialog(vault, state, t) { recovery = false }
    LaunchedEffect(page, recovery) {
        if (page == "recovery" && !recovery) {
            recoveryEnabled = null
            try { recoveryEnabled = vault.command("recovery-status").getBoolean("enabled") }
            catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { vault.report() }
        }
    }
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
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 55.dp).padding(horizontal = 4.dp) ,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (page != "home") {
                IconButton(onClick = { page = "home" }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = t("返回设置", "Back to settings"))
                }
            }
            Text(
                pageTitles[page].orEmpty(),
                modifier = Modifier.padding(start = if (page == "home") 10.dp else 3.dp).weight(1f),
                fontSize = if (page == "home") 21.sp else 18.sp,
                fontWeight = FontWeight.Medium,
            )
            if (page == "health") IconButton(onClick = { auditRevision++ }) { Icon(Icons.Default.Refresh, t("重新检查", "Check again")) }
            if (page == "home") IconButton(onClick = vault::lock) {
                Icon(Icons.Default.Lock, t("立即锁定", "Lock now"), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        key(page) {
            Column(
                Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 11.dp, vertical = 0.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                message?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
                when (page) {
                    "home" -> {
                        SettingsGroup {
                            SettingsDestination(
                                if (relayState.managed) t("已加入「${relayState.groupName.ifBlank { relayState.group }}」", "Joined ${relayState.groupName.ifBlank { relayState.group }}")
                                else if (relayState.joining) t("等待管理设备批准", "Awaiting approval from a managing device")
                                else if (relayState.legacy) t("已有旧版中继接入", "Legacy relay configured")
                                else t("未加入设备组", "No device group"),
                                if (relayState.credentialsBlocked) t("凭据读取失败，请检查接入", "Could not read credentials; review connection")
                                else if (relayState.managed || relayState.legacy) relayState.status +
                                    if (relayState.conflicts > 0) t(" · ${relayState.conflicts} 个冲突", " · ${relayState.conflicts} conflicts") else ""
                                else t("扫描其他设备上的邀请二维码加入", "Scan an invitation from one of your devices"),
                                Icons.Default.Sync, highlighted = true, onClick = relay,
                            )
                        }
                        SettingsGroup {
                            SettingsDestination(t("通用", "General"), t("语言、外观、剪贴板", "Language, appearance, clipboard"), Icons.Default.Settings) { page = "general" }
                            SettingsRule()
                            SettingsDestination(t("安全", "Security"), t("指纹解锁、自动锁定、隐私", "Biometrics, auto-lock, privacy"), Icons.Default.Lock) { page = "security" }
                            SettingsRule()
                            SettingsDestination(t("自动填充与通行密钥", "Autofill & Passkeys"), t("系统自动填充服务、凭据管理器", "System Autofill service, credential manager"), Icons.Default.Key) { page = "autofill" }
                            SettingsRule()
                            SettingsDestination(t("同步与设备", "Sync & devices"), t("设备组、成员与同步状态", "Device group, members and sync status"), Icons.Default.Sync, onClick = relay)
                            SettingsRule()
                            SettingsDestination(t("备份与导入", "Backups & import"), t("加密备份、CSV、WebDAV", "Encrypted backups, CSV, WebDAV"), Icons.Default.Archive) { page = "backup" }
                            SettingsRule()
                            SettingsDestination(t("恢复密钥", "Recovery key"), t("忘记主密码时重设", "Reset a forgotten master password"), Icons.Default.Shield) { page = "recovery" }
                        }
                        SettingsLabel(t("工具", "Tools"))
                        SettingsGroup {
                            SettingsDestination(t("密码生成器", "Password generator"), t("在本机生成随机字符", "Generate random characters locally"), Icons.Default.AutoFixHigh) { page = "generator" }
                            SettingsRule()
                            SettingsDestination(t("密码健康", "Password health"), t("检查较弱、重复使用或已过期的密码", "Check weak, reused or expired passwords"), Icons.Default.HealthAndSafety) { page = "health" }
                            SettingsRule()
                            if (devices != null) {
                                SettingsDestination(t("设备与服务", "Devices & services"), t("只读复制，不执行命令", "Read and copy; commands are not executed"), Icons.Default.Dns, onClick = devices)
                                SettingsRule()
                            }
                            SettingsDestination(t("回收站", "Trash"), t("查看、恢复或永久删除条目", "View, restore or permanently delete entries"), Icons.Default.Delete, onClick = trash)
                        }
                        SettingsGroup {
                            SettingsDestination(t("关于", "About"), "PasswordVault ${BuildConfig.VERSION_NAME} · Android", Icons.Default.Info) { page = "about" }
                        }
                    }
                    "general" -> {
                        SettingsLabel(t("外观", "Appearance"))
                        SettingsGroup {
                            val themes = linkedMapOf("system" to t("跟随系统", "System"), "light" to t("浅色", "Light"), "dark" to t("深色", "Dark"))
                            SettingsOption(t("主题", "Theme")) {
                                SettingsChoice(themes[state.settings.optString("theme", "system")].orEmpty(), themes.values.toList()) { label ->
                                    val selected = themes.entries.first { it.value == label }.key
                                    scope.launch { vault.mutate("settings", JSONObject().put("settings", JSONObject().put("theme", selected))) }
                                }
                            }
                            SettingsRule()
                            SettingsOption(t("动态取色", "Dynamic color"), t("当前使用品牌蓝", "Currently using brand blue"))
                            SettingsRule()
                            SettingsOption(t("语言", "Language"), t("应用内语言设置", "App language")) {
                                TextButton(onClick = language) { Text("简体中文 / English", fontSize = 12.sp) }
                            }
                        }
                        SettingsLabel(t("剪贴板", "Clipboard"))
                        SettingsGroup {
                            SettingsOption(t("自动清除剪贴板", "Clear clipboard"), t("30 秒 · 仅清除未被替换的内容", "30 seconds · only if unchanged"))
                            SettingsRule()
                            SettingsOption(t("标记为敏感内容", "Mark as sensitive"), t("Android 13+ 隐藏秘密预览", "Hide secret previews on Android 13+"))
                        }
                        SettingsLabel(t("笔记分类", "Note categories"))
                        SettingsDetail {
                            val categories = state.settings.optJSONArray("noteCategories")
                            if (categories != null) for (index in 0 until categories.length()) {
                                val name = categories.optString(index)
                                SettingsOption(name) {
                                    TextButton(onClick = { scope.launch {
                                        vault.mutate("category-remove", JSONObject().put("name", name).put("time", java.time.Instant.now().toString()))
                                    } }) { Text(t("移除", "Remove")) }
                                }
                            }
                            Input(t("新分类", "New category"), category, { category = it })
                            TextButton(enabled = category.isNotBlank(), onClick = { scope.launch {
                                if (vault.mutate("category-add", JSONObject().put("name", category.trim()))) category = ""
                            } }) { Text(t("添加分类", "Add category")) }
                        }
                        SettingsHint(t("删除分类只会清空归类，不会删除笔记。", "Removing a category keeps its notes."))
                    }
                    "security" -> {
                        SettingsLabel(t("解锁", "Unlock"))
                        SettingsDetail { BiometricSettings(biometric, vault, t) }
                        SettingsGroup {
                            SettingsDestination(t("修改主密码", "Change master password"), t("修改后需重新启用生物识别", "Re-enable biometrics after changing"), Icons.Default.Key) { passwordChange = true }
                        }
                        SettingsLabel(t("自动锁定", "Auto-lock"))
                        SettingsGroup {
                            val minutes = listOf(1, 5, 15, 30, 60)
                            val current = state.settings.optInt("autoLockMinutes", 60)
                            SettingsOption(t("闲置后锁定", "Lock after idle"), t("手动锁定和锁屏锁定始终有效", "Manual lock and screen lock always apply")) {
                                SettingsChoice(t("$current 分钟", "$current min"), minutes.map { t("$it 分钟", "$it min") }) { label ->
                                    val value = minutes.first { t("$it 分钟", "$it min") == label }
                                    scope.launch { vault.mutate("settings", JSONObject().put("settings", JSONObject().put("autoLockMinutes", value))) }
                                }
                            }
                            SettingsRule()
                            SettingsOption(t("切到后台", "In background"), t("在闲置期限内返回无需重新解锁", "Return before the idle timeout without unlocking"))
                            SettingsRule()
                            SettingsOption(t("屏幕关闭时锁定", "Lock when screen turns off"), t("始终开启", "Always on"))
                        }
                        SettingsLabel(t("隐私", "Privacy"))
                        SettingsGroup {
                            SettingsOption(t("阻止截屏与最近任务预览", "Block screenshots and recent previews"), t("始终开启 · FLAG_SECURE", "Always on · FLAG_SECURE"))
                            SettingsRule()
                            SettingsOption(t("本地数据", "Local data"), t("应用私有目录 · 加密保存", "App-private storage · encrypted on disk"))
                        }
                    }
                    "backup" -> {
                        SettingsLabel(t("本机加密备份", "Local encrypted backups"))
                        SettingsDetail {
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
                        }
                        SettingsLabel(t("从其他应用导入", "Import from other apps"))
                        SettingsGroup {
                            SettingsDestination(t("导入 CSV / 1Password .1pux", "Import CSV / 1Password .1pux"), t("先预览字段和重复项，再确认写入", "Preview fields and duplicates before writing"), Icons.Default.FileDownload) { capabilityPanel = "import" }
                        }
                        SettingsLabel(t("迁移导出", "Migration export"))
                        SettingsDetail {
                            FlowRow {
                                TextButton(enabled = !working, onClick = { plainExport = "json" }) {
                                    Text(t("导出明文 JSON…", "Export plain JSON…"))
                                }
                                TextButton(enabled = !working, onClick = { plainExport = "csv" }) {
                                    Text(t("导出明文 CSV…", "Export plain CSV…"))
                                }
                            }
                        }
                        SettingsLabel("WebDAV")
                        SettingsGroup {
                            SettingsDestination(t("WebDAV 备份与恢复", "WebDAV backup & restore"), t("管理服务器、上传与恢复加密备份", "Manage server, upload and restore encrypted backups"), Icons.Default.Cloud, onClick = webdav)
                        }
                    }
                    "health" -> PasswordHealthPage(audit, auditFailed, state.entries, t, openEntry) { capabilityPanel = "security" }
                    "generator" -> PasswordGeneratorControls(vault, t)
                    "recovery" -> {
                        SettingsHint(t("恢复密钥用于忘记主密码时重设，不会替代主密码，也不会上传。", "A recovery key can reset a forgotten master password. It never replaces your password or gets uploaded."))
                        Surface(shape = RoundedCornerShape(14.dp), color = if (recoveryEnabled == true) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainer) {
                            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                    Icon(if (recoveryEnabled == true) Icons.Default.CheckCircle else Icons.Default.Shield, null, tint = MaterialTheme.colorScheme.primary)
                                    Column {
                                        Text(when (recoveryEnabled) { true -> t("恢复密钥已启用", "Recovery key enabled"); false -> t("尚未设置恢复密钥", "Recovery key not enabled"); null -> t("正在读取恢复状态…", "Reading recovery status…") }, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                        Text(t("生成后需要确认抄写才能启用；停用需验证当前主密码。", "Confirm transcription before enabling; disabling requires your current password."), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                Button(enabled = recoveryEnabled != null, onClick = { recovery = true }) { Text(if (recoveryEnabled == true) t("管理恢复密钥", "Manage recovery key") else t("生成恢复密钥", "Generate recovery key")) }
                            }
                        }
                    }
                    "autofill" -> {
                        AutofillServiceStatus(t)
                        SettingsLabel(t("自动填充", "Autofill"))
                        SettingsGroup {
                            SettingsOption(t("填充前要求解锁", "Unlock before filling"), t("库已锁定时需要验证；不会绕过手动锁定", "A locked vault requires verification; manual lock is respected"))
                            SettingsRule()
                            SettingsOption(t("匹配规则", "Matching rules"), t("精确主机名匹配，子域隔离，阻止 HTTPS 降级", "Exact hostnames; isolated subdomains; HTTPS downgrade blocked"))
                        }
                        SettingsLabel(t("通行密钥", "Passkeys"))
                        SettingsDetail {
                            if (android.os.Build.VERSION.SDK_INT >= 34) {
                                Text(t("在系统凭据管理器中启用 PasswordVault 提供方。", "Enable the PasswordVault provider in the system credential manager."))
                                OutlinedButton(onClick = {
                                    try {
                                        context.startActivity(
                                            android.content.Intent(android.provider.Settings.ACTION_CREDENTIAL_PROVIDER)
                                                .setData(android.net.Uri.parse("package:" + context.packageName))
                                        )
                                    } catch (_: Exception) { vault.report() }
                                }) { Text(t("凭据提供方设置", "Credential provider settings")) }
                            } else {
                                Text(t("创建和使用通行密钥需要 Android 14 或更高版本。", "Creating and using Passkeys requires Android 14 or later."))
                            }
                            val passkeyItems = state.entries.filter { !it.optBoolean("isDeleted") && (it.optJSONArray("passkeys")?.length() ?: 0) > 0 }
                            Text(t("已保存的通行密钥", "Saved Passkeys"), style = MaterialTheme.typography.titleSmall)
                            if (passkeyItems.isEmpty()) Text(t("暂无通行密钥", "No saved Passkeys"), color = MaterialTheme.colorScheme.onSurfaceVariant)
                            passkeyItems.forEach { item ->
                                OutlinedButton(onClick = { openEntry(item.optString("id")) }, modifier = Modifier.fillMaxWidth()) {
                                    Text(item.optString("title").ifBlank { t("未命名条目", "Untitled entry") })
                                }
                            }
                        }
                    }
                    "about" -> {
                        Column(Modifier.fillMaxWidth().padding(21.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        SettingsBrand(Icons.Default.Shield)
                        Text("PasswordVault", fontSize = 21.sp, fontWeight = FontWeight.Medium)
                        Text("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) · Android")
                        Text(t("原生 Compose 界面 · vault-core 共享核心", "Native Compose interface · shared vault-core"), fontSize = 13.sp)
                        }
                        SettingsGroup { SettingsOption(t("安全模型", "Security model"), t("当前文档仍列有未解决项，不声称生产级安全", "Unresolved items remain; no production-security claim")) }
                        Text(t("安全模型仍有待解决项；当前版本不代表生产安全验收已完成。", "The security model has unresolved items; this version does not represent completed production security acceptance."), style = MaterialTheme.typography.bodyMedium)
                    }
                }
                Spacer(Modifier.height(28.dp))
            }
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

@Composable
private fun SettingsGroup(content: @Composable ColumnScope.() -> Unit) {
    SettingsCard(content)
}

@Composable
private fun SettingsDestination(
    title: String,
    subtitle: String,
    icon: ImageVector,
    highlighted: Boolean = false,
    onClick: () -> Unit,
) {
    Surface(onClick = onClick, color = MaterialTheme.colorScheme.surface) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 62.dp).padding(horizontal = 15.dp, vertical = 11.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (highlighted) Surface(shape = RoundedCornerShape(11.dp), color = MaterialTheme.colorScheme.secondaryContainer) {
                Icon(icon, null, Modifier.padding(9.dp).size(22.dp), tint = MaterialTheme.colorScheme.primary)
            } else Icon(icon, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal)
                if (subtitle.isNotEmpty()) Text(subtitle, fontSize = 12.sp, lineHeight = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun AutofillServiceStatus(t: (String, String) -> String) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var enabled by remember { mutableStateOf<Boolean?>(null) }
    DisposableEffect(context, lifecycle) {
        fun refresh() {
            enabled = if (android.os.Build.VERSION.SDK_INT >= 26) {
                runCatching {
                    context.getSystemService(android.view.autofill.AutofillManager::class.java)
                        ?.hasEnabledAutofillServices()
                }.getOrNull()
            } else false
        }
        refresh()
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) refresh()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.secondaryContainer) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(if (enabled == true) Icons.Default.CheckCircle else Icons.Default.Info, null, tint = MaterialTheme.colorScheme.primary)
                Column {
                    Text(when (enabled) {
                        true -> t("已设为自动填充服务", "Set as Autofill service")
                        false -> t("尚未设为自动填充服务", "Not set as Autofill service")
                        null -> t("请在系统设置中查看服务状态", "Check service status in system settings")
                    }, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    Text(t("在其他应用和浏览器的登录框中显示 PasswordVault 建议。", "Show PasswordVault suggestions in app and browser login fields."), fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (android.os.Build.VERSION.SDK_INT >= 26) FilledTonalButton(onClick = {
                runCatching {
                    context.startActivity(android.content.Intent(android.provider.Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE)
                        .setData(android.net.Uri.parse("package:" + context.packageName)))
                }.onFailure {
                    runCatching { context.startActivity(android.content.Intent(android.provider.Settings.ACTION_SETTINGS)) }
                }
            }) { Text(if (enabled == true) t("更改服务", "Change service") else t("去设置", "Open settings")) }
            else Text(t("Android 8 以下使用手动复制填写。", "Use manual copy below Android 8."), fontSize = 12.sp)
        }
    }
}

@Composable
private fun PasswordHealthPage(
    results: List<JSONObject>?, failed: Boolean, entries: List<JSONObject>,
    t: (String, String) -> String, openEntry: (String) -> Unit, securityCenter: () -> Unit,
) {
    var selected by remember { mutableStateOf("weak") }
    SettingsHint(t("检查弱密码、重复使用和长期未更新的密码。这不是对应用本身的安全审计。", "Checks weak, reused and old passwords. This is not a security audit of the app."))
    val warningColor = if (MaterialTheme.colorScheme.background.luminance() < 0.5f) Color(0xFFE3A04F) else Color(0xFFB86A12)
    val successColor = if (MaterialTheme.colorScheme.background.luminance() < 0.5f) Color(0xFF57C18F) else Color(0xFF2F8F63)
    val metrics = listOf("weak" to t("弱密码", "Weak"), "reused" to t("重复使用", "Reused"), "expired" to t("超过 180 天", "Over 180 days"), "breach" to t("已知泄露", "Known breaches"))
    metrics.chunked(2).forEach { pair ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            pair.forEach { (key, label) ->
                val count = results?.count { it.optBoolean(key) }
                Surface(onClick = { selected = key }, modifier = Modifier.weight(1f), shape = RoundedCornerShape(14.dp),
                    color = MaterialTheme.colorScheme.surface,
                    border = if (selected == key) BorderStroke(1.5.dp, MaterialTheme.colorScheme.primary) else null) {
                    Column(Modifier.padding(horizontal = 13.dp, vertical = 11.dp)) {
                        Text(label, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(if (key == "breach" || count == null) "—" else count.toString(), fontSize = 23.sp, fontWeight = FontWeight.Medium,
                            color = if (key == "breach" || count == null) MaterialTheme.colorScheme.onSurface else if (count > 0) warningColor else successColor)
                    }
                }
            }
        }
    }
    if (selected == "breach") {
        SettingsDetail {
            Text(t("已知泄露检查", "Known breach checks"), fontSize = 14.sp, fontWeight = FontWeight.Medium)
            SettingsHint(t("泄露检查不会自动开始。请在安全中心查看可用检查方式与数据来源。未检查不代表安全。", "Breach checks do not start automatically. Review available checks and data sources in Security center. Unchecked does not mean safe."))
            Button(onClick = securityCenter) { Text(t("打开安全中心", "Open security center")) }
        }
    } else if (failed) {
        SettingsHint(t("检查未完成，请点右上角重试。", "The check failed. Tap refresh to retry."))
    } else if (results == null) {
        Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
    } else {
        val matching = results.filter { it.optBoolean(selected) }
        if (matching.isEmpty()) Column(Modifier.fillMaxWidth().padding(horizontal = 28.dp, vertical = 49.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Default.Shield, null, Modifier.size(42.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(9.dp))
            Text(t("这一类没有问题", "No issues in this category"), fontSize = 15.sp, fontWeight = FontWeight.Medium)
        } else SettingsGroup {
            matching.forEachIndexed { index, item ->
                if (index > 0) SettingsRule()
                val entry = entries.firstOrNull { it.optString("id") == item.optString("id") }
                SettingsDestination(item.optString("title").ifBlank { t("未命名条目", "Untitled entry") },
                    entry?.optString("username").orEmpty(), Icons.Default.Key) { openEntry(item.optString("id")) }
            }
        }
    }
}
