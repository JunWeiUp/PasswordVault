package com.securepass.vault

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch

class MainActivity : FragmentActivity() {
    private lateinit var vault: VaultRepository

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val testId =
            if (BuildConfig.DEBUG)
                intent.getStringExtra("uiTestVault")?.let {
                    runCatching { java.util.UUID.fromString(it).toString() }.getOrNull()
                }
            else null
        vault =
            if (testId != null) {
                androidx.lifecycle
                    .ViewModelProvider(
                        this,
                        object : androidx.lifecycle.ViewModelProvider.Factory {
                            @Suppress("UNCHECKED_CAST")
                            override fun <T : androidx.lifecycle.ViewModel> create(
                                modelClass: Class<T>
                            ): T = QaVaultModel(applicationContext, testId) as T
                        },
                    )[QaVaultModel::class.java]
                    .repository
            } else (application as VaultApplication).vault
        vault.foreground()
        if (
            !(BuildConfig.DEBUG && testId != null && intent.getBooleanExtra("qaScreenshots", false))
        )
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent { VaultApp(vault) }
    }

    override fun onStart() {
        super.onStart()
        vault.foreground()
    }

    override fun onUserInteraction() {
        super.onUserInteraction()
        vault.checkIdle()
        vault.activity()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) vault.background()
    }
}

private class QaVaultModel(context: android.content.Context, id: String) :
    androidx.lifecycle.ViewModel() {
    val repository =
        VaultRepository(context.applicationContext, java.io.File(context.cacheDir, "ui-test-$id"))

    override fun onCleared() {
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
            repository.close()
        }
    }
}

@Composable
fun VaultApp(vault: VaultRepository) {
    val state by vault.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("ui", 0) }
    var pendingBiometricSetup by remember { mutableStateOf(false) }
    var chinese by remember { mutableStateOf(prefs.getBoolean("chinese", true)) }
    val t: (String, String) -> String = { zh, en -> if (chinese) zh else en }
    val dark =
        when (state.settings.optString("theme")) {
            "dark" -> true
            "light" -> false
            else -> isSystemInDarkTheme()
        }
    SideEffect {
        (context as? android.app.Activity)?.window?.let { window ->
            window.statusBarColor = if (dark) 0xFF121419.toInt() else 0xFFF3F5F8.toInt()
            window.navigationBarColor =
                if (dark) 0xFF121419.toInt() else 0xFFF3F5F8.toInt()
            androidx.core.view.WindowCompat.getInsetsController(window, window.decorView).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    LegacyVaultTheme(dark) {
        Surface(Modifier.fillMaxSize()) {
            if (!state.unlocked)
                UnlockScreen(vault, state, t, chinese, changeLanguage = {
                    chinese = !chinese
                    prefs.edit().putBoolean("chinese", chinese).apply()
                }, offerBiometrics = { pendingBiometricSetup = true })
            else if (pendingBiometricSetup)
                BiometricOnboarding(vault, t) { pendingBiometricSetup = false }
            else
                key(state.unlocked) {
                    VaultWorkspace(vault, state, t) {
                        chinese = !chinese
                        prefs.edit().putBoolean("chinese", chinese).apply()
                    }
                }
            if (state.error != null && state.unlocked)
                AlertDialog(
                    onDismissRequest = vault::clearMessage,
                    title = { Text(t("操作未完成", "Could not complete")) },
                    text = { Text(state.error!!) },
                    confirmButton = {
                        TextButton(onClick = vault::clearMessage) { Text(t("好", "OK")) }
                    },
                )
        }
    }
}

@Composable
fun UnlockScreen(
    vault: VaultRepository,
    state: VaultState,
    t: (String, String) -> String,
    chinese: Boolean,
    changeLanguage: () -> Unit,
    offerBiometrics: () -> Unit = {},
) {
    val activity = LocalContext.current as FragmentActivity
    val biometric = remember { BiometricVault(activity) }
    var recovery by remember { mutableStateOf(false) }
    if (recovery) RecoveryDialog(vault, state, t) { recovery = false }
    var backupUri by remember { mutableStateOf<android.net.Uri?>(null) }
    var backupPassword by remember { mutableStateOf("") }
    var legacyPassword by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    var onboardingStep by remember { mutableIntStateOf(0) }
    BackHandler(enabled = !state.exists && onboardingStep > 0) { onboardingStep = 0 }
    val importer =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            backupUri = uri
        }
    fun authenticate() {
        if (!state.exists) offerBiometrics()
        val value = password
        scope.launch {
            vault.authenticate(value, !state.exists, legacyPassword)
            password = ""
            confirm = ""
            legacyPassword = ""
        }
    }
    val canAuthenticate = state.ready && !state.busy && password.isNotEmpty() && (state.exists || password == confirm)
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).safeDrawingPadding()) {
        if (!state.exists && onboardingStep == 1) {
            Row(Modifier.fillMaxWidth().heightIn(min = 55.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { onboardingStep = 0 }) { Icon(Icons.Outlined.ArrowBack, t("返回", "Back")) }
                Text(t("设置主密码", "Set master password"), fontSize = 18.sp, fontWeight = FontWeight.Medium)
            }
        }
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val availableHeight = maxHeight
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).heightIn(min = availableHeight).padding(21.dp).imePadding(),
                verticalArrangement = if (state.exists || onboardingStep == 0) Arrangement.Center else Arrangement.Top,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                if (!state.exists && onboardingStep == 0) {
                    SettingsBrand(Icons.Outlined.Shield)
                    Spacer(Modifier.height(14.dp))
                    Text(t("欢迎使用 PasswordVault", "Welcome to PasswordVault"), fontSize = 21.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(5.dp))
                    Text(t("账号、验证码、钱包和笔记，本机加密保存，可与其他设备端到端加密同步。", "Accounts, codes, wallets and notes, encrypted locally with end-to-end device sync."), fontSize = 13.sp, lineHeight = 19.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                    Spacer(Modifier.height(20.dp))
                    listOf(
                        Triple(Icons.Outlined.Lock, t("只有你能打开", "Only you can open it"), t("主密码不会离开这台手机", "Your master password stays on this phone")),
                        Triple(Icons.Outlined.Sync, t("与其他设备同步", "Sync with your devices"), t("中继只转发密文，入组后由主库授权", "The relay carries ciphertext; your primary vault grants access")),
                        Triple(Icons.Outlined.Key, t("在其他应用中填充", "Fill in other apps"), t("系统自动填充与通行密钥", "System Autofill and Passkeys")),
                    ).forEach { (icon, title, subtitle) ->
                        Row(Modifier.fillMaxWidth().padding(bottom = 13.dp), horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                            Icon(icon, null, Modifier.size(21.dp), tint = MaterialTheme.colorScheme.primary)
                            Column {
                                Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                Text(subtitle, fontSize = 12.sp, lineHeight = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                    AuthenticationSteps(0)
                    Button(onClick = { onboardingStep = 1 }, Modifier.fillMaxWidth()) { Text(t("新建密码库", "Create vault")) }
                    TextButton(onClick = { onboardingStep = 1 }, Modifier.fillMaxWidth()) { Text(t("我已在其他设备上使用", "I already use it on another device")) }
                } else {
                    if (state.exists) {
                        SettingsBrand(Icons.Outlined.Lock)
                        Spacer(Modifier.height(14.dp))
                        Text(t("PasswordVault 已锁定", "PasswordVault is locked"), fontSize = 21.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
                        Spacer(Modifier.height(5.dp))
                        Text(if (biometric.enabled && biometric.available) t("输入主密码，或使用指纹解锁。", "Enter your master password or use biometrics.") else t("输入主密码以打开密码库。", "Enter your master password to open the vault."), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                        Spacer(Modifier.height(20.dp))
                    } else {
                        Text(t("主密码用于加密本机密码库，忘记后无法找回（除非设置恢复密钥）。至少 1 个字符；建议使用长密码。", "Your master password encrypts this vault. If forgotten, it requires a recovery key to reset. At least one character; a long password is recommended."), fontSize = 12.sp, lineHeight = 18.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.height(14.dp))
                    }
                    if (state.legacyAvailable) {
                        Text(t("发现旧版资料，验证旧密码后迁移；保留原文件。", "Legacy data found. Verify the original password to migrate; source files are retained."), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        AuthenticationInput(t("旧版主密码", "Legacy master password"), legacyPassword, { legacyPassword = it }, enabled = !state.busy)
                        Spacer(Modifier.height(12.dp))
                    }
                    AuthenticationInput(t("主密码", "Master password"), password, { password = it }, enabled = !state.busy,
                        submit = if (state.exists) ({ if (canAuthenticate) authenticate() }) else null,
                        canSubmit = canAuthenticate, busy = state.busy, submitLabel = t("解锁", "Unlock"))
                    if (state.error != null) {
                        Text(state.error, Modifier.fillMaxWidth().padding(start = 5.dp, top = 4.dp), fontSize = 11.sp, lineHeight = 16.sp, color = MaterialTheme.colorScheme.error)
                    }
                    Spacer(Modifier.height(12.dp))
                    if (!state.exists) {
                        AuthenticationInput(t("再次输入", "Confirm password"), confirm, { confirm = it }, enabled = !state.busy)
                        Text(if (confirm.isEmpty()) t("两次输入需要一致", "Both passwords must match") else if (confirm == password) t("两次输入一致", "Passwords match") else t("两次输入不一致", "Passwords do not match"), Modifier.fillMaxWidth().padding(start = 5.dp, top = 4.dp), fontSize = 11.sp, color = if (confirm.isNotEmpty() && confirm != password) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        Spacer(Modifier.height(18.dp))
                        AuthenticationSteps(1)
                        Button(onClick = ::authenticate, enabled = canAuthenticate, modifier = Modifier.fillMaxWidth()) {
                            if (state.busy) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                            else Text(t("继续", "Continue"))
                        }
                        TextButton(enabled = !state.busy && password.isNotEmpty() && password == confirm, onClick = { importer.launch(arrayOf("application/json", "application/octet-stream", "text/*")) }, modifier = Modifier.fillMaxWidth()) { Text(t("从已有备份创建…", "Create from backup…")) }
                        SettingsHint(t("创建后可在「设置 › 安全」启用指纹，并加入设备组或导入备份。", "After creating your vault, enable biometrics in Settings › Security, join a device group or import a backup."))
                    }
                    if (state.exists && biometric.enabled && biometric.available) {
                        FilledTonalButton(enabled = !state.busy, onClick = {
                            biometric.unlock { key -> if (key != null) scope.launch {
                                try { vault.unlockBiometric(key) } catch (_: Exception) { vault.report() }
                            } }
                        }, modifier = Modifier.fillMaxWidth()) {
                            Icon(Icons.Outlined.Fingerprint, null, Modifier.size(17.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(t("使用指纹 / 人脸解锁", "Use biometric unlock"))
                        }
                    }
                    if (state.exists || state.legacyAvailable) TextButton(enabled = !state.busy, onClick = { recovery = true }, modifier = Modifier.padding(top = 11.dp)) { Text(t("忘记主密码？", "Forgot master password?")) }
                }
                TextButton(onClick = changeLanguage) { Text(if (chinese) "English" else "简体中文", fontSize = 12.sp) }
            }
        }
    }
    backupUri?.let { uri ->
        AlertDialog(
            onDismissRequest = {
                backupUri = null
                backupPassword = ""
            },
            title = { Text(t("备份文件密码", "Backup file password")) },
            text = {
                Input(
                    t("未加密 JSON / CSV 可留空", "Leave blank for unencrypted JSON / CSV"),
                    backupPassword,
                    { backupPassword = it },
                    secret = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        val filePassword = backupPassword
                        backupUri = null
                        scope.launch {
                            try {
                                val content =
                                    kotlinx.coroutines.withContext(
                                        kotlinx.coroutines.Dispatchers.IO
                                    ) {
                                        activity.contentResolver.openInputStream(uri)?.use { input
                                            ->
                                            val out = java.io.ByteArrayOutputStream()
                                            val bytes = ByteArray(8192)
                                            while (true) {
                                                val count = input.read(bytes)
                                                if (count < 0) break
                                                require(out.size() + count <= 64 * 1024 * 1024)
                                                out.write(bytes, 0, count)
                                            }
                                            out.toString("UTF-8")
                                        } ?: error("No input")
                                    }
                                offerBiometrics()
                                vault.createFromBackup(
                                    content,
                                    filePassword,
                                    password,
                                    if (
                                        content.trimStart().startsWith("{") ||
                                            content.trimStart().startsWith("[")
                                    )
                                        "json"
                                    else "csv",
                                )
                                password = ""
                                confirm = ""
                                backupPassword = ""
                            } catch (_: Exception) {
                                vault.report()
                            }
                        }
                    }
                ) {
                    Text(t("导入并创建", "Import and create"))
                }
            },
            dismissButton = {
                TextButton(
                    onClick = {
                        backupUri = null
                        backupPassword = ""
                    }
                ) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
    }
}

@Composable
private fun BiometricOnboarding(vault: VaultRepository, t: (String, String) -> String, done: () -> Unit) {
    val activity = LocalContext.current as FragmentActivity
    val biometric = remember { BiometricVault(activity) }
    val scope = rememberCoroutineScope()
    var working by remember { mutableStateOf(false) }
    var incomplete by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).safeDrawingPadding().verticalScroll(rememberScrollState()).padding(21.dp),
        verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        SettingsBrand(Icons.Outlined.Fingerprint)
        Spacer(Modifier.height(14.dp))
        Text(t("使用指纹解锁？", "Use biometric unlock?"), fontSize = 21.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(5.dp))
        Text(t("主密码仍然有效。设备新增指纹后需要重新输入主密码。", "Your master password remains valid. Adding a fingerprint requires your master password again."), fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        Spacer(Modifier.height(20.dp))
        AuthenticationSteps(2)
        if (!biometric.available) SettingsHint(t("此设备当前没有可用的强生物识别，可稍后在设置中启用。", "Strong biometrics are currently unavailable. You can enable them later in Settings."))
        if (incomplete) SettingsHint(t("验证未完成，仍可使用主密码。", "Verification did not finish. You can still use your master password."))
        Button(enabled = !working && biometric.available, onClick = {
            working = true
            incomplete = false
            scope.launch {
                try {
                    biometric.enroll(vault.biometricKey()) { success ->
                        working = false
                        if (success) done() else incomplete = true
                    }
                } catch (_: Exception) { working = false; incomplete = true; vault.report() }
            }
        }, modifier = Modifier.fillMaxWidth()) {
            if (working) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
            else Text(t("启用指纹解锁", "Enable biometric unlock"))
        }
        TextButton(enabled = !working, onClick = done, modifier = Modifier.fillMaxWidth()) { Text(t("以后再说", "Not now")) }
    }
}

val LocalEditorEnabled = staticCompositionLocalOf { true }

@Composable
fun Input(
    label: String,
    value: String,
    change: (String) -> Unit,
    modifier: Modifier = Modifier,
    secret: Boolean = false,
    multiline: Boolean = false,
    enabled: Boolean = LocalEditorEnabled.current,
) {
    OutlinedTextField(
        value,
        change,
        enabled = enabled,
        label = { Text(label) },
        modifier = modifier.fillMaxWidth(),
        visualTransformation =
            if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        colors =
            OutlinedTextFieldDefaults.colors(
                unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                focusedContainerColor = MaterialTheme.colorScheme.surface,
            ),
        singleLine = !multiline,
        minLines = if (multiline) 5 else 1,
        keyboardOptions =
            androidx.compose.foundation.text.KeyboardOptions(
                autoCorrectEnabled = false,
                keyboardType =
                    if (secret) androidx.compose.ui.text.input.KeyboardType.Password
                    else androidx.compose.ui.text.input.KeyboardType.Text,
            ),
    )
}
