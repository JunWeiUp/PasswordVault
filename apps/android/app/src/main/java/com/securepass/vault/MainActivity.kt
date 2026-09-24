package com.securepass.vault

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
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
        if (
            !(BuildConfig.DEBUG && testId != null && intent.getBooleanExtra("qaScreenshots", false))
        )
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        setContent { VaultApp(vault) }
    }

    override fun onStart() {
        super.onStart()
        vault.checkIdle()
    }

    override fun onUserInteraction() {
        super.onUserInteraction()
        vault.activity()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations && !vault.systemFileFlow) vault.lock()
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
            window.statusBarColor = if (dark) 0xFF171A21.toInt() else 0xFFFAF9F6.toInt()
            window.navigationBarColor =
                if (dark) 0xFF1D212A.toInt() else android.graphics.Color.WHITE
            androidx.core.view.WindowCompat.getInsetsController(window, window.decorView).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    LegacyVaultTheme(dark) {
        Surface(Modifier.fillMaxSize()) {
            if (!state.unlocked)
                UnlockScreen(vault, state, t, chinese) {
                    chinese = !chinese
                    prefs.edit().putBoolean("chinese", chinese).apply()
                }
            else
                key(state.unlocked) {
                    VaultWorkspace(vault, state, t) {
                        chinese = !chinese
                        prefs.edit().putBoolean("chinese", chinese).apply()
                    }
                }
            if (state.error != null)
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
) {
    val activity = LocalContext.current as FragmentActivity
    val biometric = remember { BiometricVault(activity) }
    var backupUri by remember { mutableStateOf<android.net.Uri?>(null) }
    var backupPassword by remember { mutableStateOf("") }
    var legacyPassword by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var confirm by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()
    val importer =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            backupUri = uri
        }
    Column(
        Modifier.fillMaxSize()
            .safeDrawingPadding()
            .padding(24.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Spacer(Modifier.height(32.dp))
        Icon(
            Icons.Outlined.Shield,
            null,
            Modifier.size(56.dp),
            tint = MaterialTheme.colorScheme.primary,
        )
        Text("PasswordVault", style = MaterialTheme.typography.headlineLarge)
        Text(
            if (state.exists) t("解锁资料库", "Unlock your vault")
            else t("创建本机加密资料库", "Create an encrypted vault"),
            style = MaterialTheme.typography.titleLarge,
        )
        if (state.legacyAvailable) {
            Text(
                t(
                    "发现旧版资料，验证旧密码后迁移；保留原文件。",
                    "Legacy data found. Verify the original password to migrate; source files are retained.",
                )
            )
            Input(
                t("旧版主密码", "Legacy master password"),
                legacyPassword,
                { legacyPassword = it },
                secret = true,
            )
        }
        Input(t("主密码", "Master password"), password, { password = it }, secret = true)
        if (!state.exists)
            Input(t("确认主密码", "Confirm password"), confirm, { confirm = it }, secret = true)
        Button(
            onClick = {
                val value = password
                scope.launch {
                    vault.authenticate(value, !state.exists, legacyPassword)
                    password = ""
                    confirm = ""
                    legacyPassword = ""
                }
            },
            enabled =
                state.ready &&
                    !state.busy &&
                    password.isNotEmpty() &&
                    (state.exists || password.isNotEmpty() && password == confirm),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(if (state.exists) t("解锁", "Unlock") else t("创建资料库", "Create vault"))
        }
        Text(
            t(
                "主密码不设最小长度或强度门槛。主密码不会保存，资料始终加密写入本机。",
                "No minimum length or strength requirement. The master password is not stored; data on disk stays encrypted.",
            ),
            style = MaterialTheme.typography.bodySmall,
        )
        if (state.exists && biometric.enabled && biometric.available)
            OutlinedButton(
                onClick = {
                    biometric.unlock { key ->
                        if (key != null)
                            scope.launch {
                                try {
                                    vault.unlockBiometric(key)
                                } catch (_: Exception) {
                                    vault.report()
                                }
                            }
                    }
                }
            ) {
                Text(t("使用指纹 / 人脸解锁", "Use biometric unlock"))
            }
        if (!state.exists) {
            OutlinedButton(
                enabled = !state.busy && password.isNotEmpty() && password == confirm,
                onClick = {
                    importer.launch(
                        arrayOf("application/json", "application/octet-stream", "text/*")
                    )
                },
            ) {
                Text(t("从已有备份创建…", "Create from backup…"))
            }
            Text(
                t(
                    "先确认新主密码，再选择备份并输入文件的原密码。",
                    "Confirm a new master password, then select a backup and enter its original password.",
                ),
                style = MaterialTheme.typography.bodySmall,
            )
        }
        TextButton(onClick = changeLanguage) { Text(if (chinese) "English" else "简体中文") }
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
