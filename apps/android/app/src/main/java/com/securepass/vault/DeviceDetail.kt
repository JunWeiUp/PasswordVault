package com.securepass.vault

import android.content.ClipboardManager
import android.content.ClipData
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.json.JSONObject

// Shared by both detail screens. Neither revealed fields nor loaded documents survive backgrounding.
internal val LocalDetailCopy = staticCompositionLocalOf<((String) -> Unit)?> { null }

@Composable
internal fun DetailPrivacy(
    vault: VaultRepository,
    entryId: String,
    content: @Composable () -> Unit,
) {
    val state by vault.state.collectAsState()
    val owner = LocalLifecycleOwner.current
    val context = LocalContext.current
    var active by remember(owner) { mutableStateOf(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) }
    val clipboard = remember(context) { context.getSystemService(ClipboardManager::class.java) }
    var copied by remember(entryId) { mutableStateOf<ClipData?>(null) }
    fun clearCopy() {
        val own = copied ?: return
        copied = null
        val current = clipboard.primaryClip
        if (current != null && current.itemCount > 0 && own.itemCount > 0 &&
            current.description.label == own.description.label && current.getItemAt(0).text == own.getItemAt(0).text) {
            if (android.os.Build.VERSION.SDK_INT >= 28) clipboard.clearPrimaryClip()
            else clipboard.setPrimaryClip(ClipData.newPlainText("", ""))
        }
    }
    DisposableEffect(owner, entryId) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_STOP || event == Lifecycle.Event.ON_DESTROY) {
                active = false
                clearCopy()
            } else if (event == Lifecycle.Event.ON_START) active = true
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer); clearCopy() }
    }
    LaunchedEffect(state.unlocked) { if (!state.unlocked) clearCopy() }
    if (active && state.unlocked) key(entryId) {
        CompositionLocalProvider(LocalDetailCopy provides { value ->
            if (active && vault.state.value.unlocked) {
                vault.copy(value)
                copied = clipboard.primaryClip
            }
        }) { content() }
    }
}

/** Read-only format-7 device view. Navigation, editing and deletion remain with the caller. */
@Composable
internal fun DeviceDetail(item: JSONObject, vault: VaultRepository, t: (String, String) -> String) {
    DetailPrivacy(vault, item.optString("id")) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 11.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            DetailHero(item, t)
            if (item.optBoolean("isDeleted")) Text(t("此条目在回收站中。", "This entry is in Trash."), color = MaterialTheme.colorScheme.error)
            DeviceDetailContent(item, vault, t)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DeviceDetailContent(item: JSONObject, vault: VaultRepository, t: (String, String) -> String) {
    val device = item.optJSONObject("device")
    Text(t("只读查看与复制；手机不会连接设备或执行命令。", "View and copy only. This phone does not connect to devices or execute commands."),
        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    if (device == null || device.optInt("version") != 1) {
        Text(t("无法读取此设备格式，请在桌面端检查。", "Cannot read this device format. Check it on desktop."), color = MaterialTheme.colorScheme.error)
        return
    }
    DetailSection(t("连接", "Connection")) {
        DetailField(t("主机", "Host"), device.optString("host"), vault, t, monospace = true)
        if (device.has("port")) DetailField(t("端口", "Port"), device.optString("port"), vault, t, monospace = true)
        DetailField(t("用户名", "Username"), device.optString("username"), vault, t)
        val method = when (device.optString("authMethod")) {
            "password" -> t("密码", "Password")
            "key" -> t("私钥", "Private key")
            "agent" -> t("SSH Agent（桌面端）", "SSH agent (desktop)")
            else -> device.optString("authMethod")
        }
        DetailValue(t("认证方式", "Authentication"), method)
        if (device.optString("password").isNotEmpty()) DetailField(t("密码", "Password"), device.optString("password"), vault, t, secret = true)
        if (device.optString("privateKey").isNotEmpty()) DetailField(t("私钥", "Private key"), device.optString("privateKey"), vault, t, secret = true, monospace = true)
        val aliases = device.optJSONArray("aliases")
        if (aliases != null && aliases.length() > 0) DetailField(t("别名", "Aliases"), (0 until aliases.length()).joinToString("\n") { aliases.optString(it) }, vault, t)
    }
    device.optJSONArray("services")?.objects()?.forEachIndexed { index, service ->
        key(service.optString("id"), index) {
            DetailSection(service.optString("name").ifBlank { t("服务 ${index + 1}", "Service ${index + 1}") }) {
                DetailValue(t("类型", "Type"), service.optString("kind"))
                if (service.has("remotePort")) DetailField(t("远程端口", "Remote port"), service.optString("remotePort"), vault, t)
                if (service.has("localPort")) DetailField(t("本地端口", "Local port"), service.optString("localPort"), vault, t)
                if (service.optString("path").isNotEmpty()) DetailField(t("路径", "Path"), service.optString("path"), vault, t, monospace = true)
            }
        }
    }
    Text(t("资料文件 · ${(device.optJSONArray("commands")?.length() ?: 0) + (device.optJSONArray("files")?.length() ?: 0)}", "Documents · ${(device.optJSONArray("commands")?.length() ?: 0) + (device.optJSONArray("files")?.length() ?: 0)}"), Modifier.padding(start = 5.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
    device.optJSONArray("commands")?.objects()?.forEachIndexed { index, document ->
        key(document.optString("id"), index) {
            var open by remember { mutableStateOf(false) }
            Surface(onClick = { open = true }, color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(16.dp)) {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.Outlined.Description, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Column(Modifier.weight(1f)) {
                        Text(document.optString("title").ifBlank { t("资料 ${index + 1}", "Document ${index + 1}") }, style = MaterialTheme.typography.bodyMedium)
                        Text(t("文档 · 只读查看与复制", "Document · view and copy only"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (open) ModalBottomSheet(onDismissRequest = { open = false }, containerColor = MaterialTheme.colorScheme.surface) {
                Column(Modifier.fillMaxWidth().heightIn(max = 520.dp).verticalScroll(rememberScrollState()).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(document.optString("title").ifBlank { t("设备文档", "Device document") }, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.titleLarge)
                    DetailField(t("文档内容", "Document content"), document.optString("text"), vault, t, secret = true, monospace = true)
                    Text(t("手机上不执行命令或脚本。", "Commands and scripts are not executed on this phone."), Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    device.optJSONArray("files")?.objects()?.forEachIndexed { index, file ->
        key(file.optString("attachmentId"), index) { DeviceFileDetail(item, file, vault, t) }
    }
    if (device.optString("notes").isNotBlank()) DetailSection(t("说明", "Description")) {
        DetailField(t("设备备注", "Device notes"), device.optString("notes"), vault, t, secret = true)
    }
    if (item.optString("note").isNotBlank()) DetailSection(t("备注", "Notes")) {
        DetailField(t("备注", "Notes"), item.optString("note"), vault, t, secret = true)
    }
    if (device.optJSONArray("commands")?.length() == 0 && device.optJSONArray("files")?.length() == 0)
        Text(t("尚无设备文档", "No device documents"), color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun DeviceFileDetail(item: JSONObject, file: JSONObject, vault: VaultRepository, t: (String, String) -> String) {
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    DetailGroup {
        Row(Modifier.padding(start = 16.dp, end = 12.dp, top = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.Description, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(file.optString("name").ifBlank { t("设备文档", "Device document") }, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        }
        Text(listOf(file.optString("mime"), if (file.has("size")) "${file.optLong("size")} B" else "").filter { it.isNotEmpty() }.joinToString(" · "), modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp), style = MaterialTheme.typography.bodySmall)
        if (text == null) OutlinedButton(
            enabled = !loading && !item.optBoolean("isDeleted"),
            onClick = {
                scope.launch {
                    loading = true; failed = false
                    try {
                        val result = vault.command("devices-file-read", JSONObject().put("id", item.getString("id")).put("attachmentId", file.getString("attachmentId")))
                        check(result.has("text"))
                        text = result.getString("text")
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { failed = true }
                    finally { loading = false }
                }
            },
        ) { Text(if (loading) t("正在读取…", "Reading…") else t("读取加密文档", "Read encrypted document")) }
        text?.let { content ->
            DetailField(t("文档内容", "Document content"), content, vault, t, secret = true, monospace = true)
            TextButton(onClick = { text = null }) { Text(t("关闭文档", "Close document")) }
        }
        if (failed) Text(t("无法读取文档，请确认附件已同步且格式受支持后重试。", "Could not read document. Check that the attachment has synced and its format is supported, then retry."), color = MaterialTheme.colorScheme.error)
        if (item.optBoolean("isDeleted")) Text(t("恢复条目后可读取文档。", "Restore the entry to read its documents."), style = MaterialTheme.typography.bodySmall)
    }
}
