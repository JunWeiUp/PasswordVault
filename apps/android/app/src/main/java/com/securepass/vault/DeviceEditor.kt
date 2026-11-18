package com.securepass.vault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * Create or edit a format-7 device: name, host, port, username, password and description. Aliases,
 * services, documents, files and unknown fields are preserved by [DevicePayload.apply]. The phone
 * never connects to the device or executes its commands.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DeviceEditor(
    original: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    restoredDraft: Boolean,
    close: () -> Unit,
) {
    val state by vault.state.collectAsState()
    val id = original.optString("id")
    val persisted = state.entries.firstOrNull { it.optString("id") == id }
    val existing = persisted != null
    // Drafts are applied on top of the stored record, so fields the phone does not show stay intact.
    val base = remember(id) { persisted ?: original }
    val initial = remember(id) { DevicePayload.form(original) }
    var form by remember(id) { mutableStateOf(initial) }
    var saving by remember { mutableStateOf(false) }
    var saveFailed by remember { mutableStateOf(false) }
    var failureKind by remember { mutableStateOf<String?>(null) }
    var discard by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val error = DevicePayload.validate(form)
    val dirty = form != DevicePayload.form(base) || restoredDraft

    fun update(next: DeviceForm) {
        form = next
        saveFailed = false
        vault.pendingDraft = runCatching { DevicePayload.apply(base, next).toString() }.getOrElse {
            // Invalid input is still kept as a draft so locking never loses it (the port stays stored).
            runCatching {
                DevicePayload.apply(base, next.copy(host = "", port = DevicePayload.form(base).port, title = next.title.ifBlank { " " })).apply {
                    put("title", next.title); getJSONObject("device").put("host", next.host)
                }.toString()
            }.getOrElse { JSONObject(base.toString()).put("title", next.title).toString() }
        }
        vault.activity()
    }
    fun cancel() {
        if (saving) return
        if (dirty) discard = true else { vault.discardDraft(); close() }
    }
    fun save() {
        if (saving || error != null) return
        if (!(if (existing) DevicePayload.editable(base, vault.canEdit(base)) else DevicePayload.canCreate(state.settings, vault.canWriteLibrary()))) {
            failureKind = "ReadOnly"; saveFailed = true; return
        }
        val payload = DevicePayload.apply(base, form)
        saving = true
        saveFailed = false
        scope.launch {
            try {
                if (vault.save(payload)) {
                    vault.discardDraft()
                    close()
                } else {
                    failureKind = vault.lastFailureKind
                    saveFailed = true
                    vault.clearMessage()
                }
            } finally { saving = false }
        }
    }

    Dialog(
        onDismissRequest = ::cancel,
        properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = false, securePolicy = androidx.compose.ui.window.SecureFlagPolicy.Inherit, decorFitsSystemWindows = false),
    ) {
        EditorDialogBars()
        BackHandler(onBack = ::cancel)
        CompositionLocalProvider(LocalEditorEnabled provides !saving, LocalAccountForm provides true) {
            Scaffold(
                containerColor = MaterialTheme.colorScheme.background,
                topBar = {
                    TopAppBar(
                        expandedHeight = 55.dp,
                        colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
                        title = { Text(if (existing) t("编辑设备", "Edit device") else t("新建设备", "New device"), style = MaterialTheme.typography.titleLarge) },
                        navigationIcon = { IconButton(enabled = !saving, onClick = ::cancel) { Icon(Icons.Outlined.Close, t("关闭", "Close")) } },
                        actions = {
                            Button(
                                enabled = !saving && error == null && (dirty || !existing),
                                onClick = ::save,
                                modifier = Modifier.padding(end = 12.dp).heightIn(min = 40.dp),
                                shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
                            ) { Text(if (saving) t("保存中…", "Saving…") else t("保存", "Save")) }
                        },
                    )
                },
            ) { padding ->
                Column(
                    Modifier.padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 11.dp).padding(top = 8.dp, bottom = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    if (saveFailed) SaveFailureBanner(existing, t, ::save, {
                        vault.copy(saveFailureDetails(failureKind, "device", existing, android.os.Build.VERSION.SDK_INT, BuildConfig.VERSION_NAME))
                    }, enabled = !saving && error == null, stale = failureKind == "StaleEdit")
                    EditorFormSection {
                        EditorField(t("名称 *", "Name *"), form.title, { update(form.copy(title = it)) }, vault, t)
                        EditorHeading(t("连接", "Connection"))
                        EditorField(t("主机", "Host"), form.host, { update(form.copy(host = it)) }, vault, t)
                        if (error == DeviceFormError.HOST) Text(t("主机只能包含字母、数字和 . - _ : [ ] %，不能以 - 开头或包含空格。", "Hosts may contain only letters, digits and . - _ : [ ] %, and cannot start with - or contain spaces."), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                        EditorField(t("端口", "Port"), form.port, { update(form.copy(port = it.filter(Char::isDigit).take(5))) }, vault, t, numeric = true)
                        if (error == DeviceFormError.PORT) Text(t("端口需为 1–65535。", "Port must be 1–65535."), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                        EditorField(t("用户名", "Username"), form.username, { update(form.copy(username = it)) }, vault, t)
                        EditorField(t("密码", "Password"), form.password, { update(form.copy(password = it)) }, vault, t, secret = true)
                        EditorField(t("说明", "Description"), form.notes, { update(form.copy(notes = it)) }, vault, t, lines = 4)
                        if (error == DeviceFormError.TOO_LONG) Text(t("内容过长。", "Content is too long."), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }
                    val device = base.optJSONObject("device")
                    val kept = listOf("aliases", "services", "commands", "files").sumOf { device?.optJSONArray(it)?.length() ?: 0 }
                    Text(
                        if (kept > 0) t("别名、服务、资料文件和私钥等其他内容（$kept 项）会原样保留，请在桌面端修改。", "Aliases, services, documents, files and the private key ($kept items) are kept as they are; edit them on desktop.")
                        else t("别名、服务、资料文件和私钥请在桌面端添加。", "Add aliases, services, documents and private keys on desktop."),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(t("手机只保存连接信息，不会连接设备或执行命令。", "The phone only stores connection details; it never connects or runs commands."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    if (discard) AlertDialog(
        onDismissRequest = { discard = false },
        title = { Text(t("保存这次修改？", "Save your changes?")) },
        text = { Text(t("返回前保存修改，或放弃这次编辑。", "Save before returning, or discard this edit.")) },
        confirmButton = { TextButton(enabled = !saving && error == null, onClick = { discard = false; save() }) { Text(t("保存", "Save")) } },
        dismissButton = {
            Row {
                TextButton(enabled = !saving, onClick = { vault.discardDraft(); close() }) { Text(t("放弃修改", "Discard")) }
                TextButton(onClick = { discard = false }) { Text(t("继续编辑", "Keep editing")) }
            }
        },
    )
}
