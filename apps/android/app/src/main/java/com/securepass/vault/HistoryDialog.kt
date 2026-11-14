package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Instant

/** Shared sheet geometry for the Android design's item actions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VaultActionSheet(
    title: String,
    description: String,
    dismiss: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = dismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.background,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding()
                .padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            if (description.isNotEmpty()) Text(description, style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            content()
        }
    }
}

@Composable
internal fun HistoryDialog(vault: VaultRepository, id: String, t: (String, String) -> String, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    var rows by remember { mutableStateOf<List<JSONObject>>(emptyList()) }
    var total by remember { mutableStateOf(0) }
    var selected by remember { mutableStateOf<JSONObject?>(null) }
    var reveal by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var confirm by remember { mutableStateOf<String?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    suspend fun load(append: Boolean = false) {
        enabled = vault.command("history-status").getBoolean("enabled")
        val result = vault.command("history-list", JSONObject().put("id", id).put("offset", if (append) rows.size else 0))
        val array = result.getJSONArray("revisions")
        val page = (0 until array.length()).map { array.getJSONObject(it) }
        total = result.getInt("total"); rows = if (append) rows + page else page
        loaded = true
    }
    val run: (suspend () -> Unit) -> Unit = { action -> if (!working) { working = true; message = null; scope.launch { try { action() } catch (_: Exception) { message = t("操作失败，请先保存草稿并检查权限。", "Operation failed. Save pending drafts and check permissions.") } finally { working = false } } } }
    LaunchedEffect(id) { run { load() } }
    VaultActionSheet(
        t("版本历史", "Version history"),
        t("每次保存生成一个加密版本。恢复会创建新版本，不会删除现有版本。", "Each save creates an encrypted version. Restoring creates a new version and preserves existing versions."),
        { if (!working) close() },
    ) {
        if (loaded && !enabled) {
            LegacySection {
                Text(t("尚未启用完整历史", "Complete history is not enabled"), style = MaterialTheme.typography.titleMedium)
                Text(t("启用将升级资料库格式，旧客户端无法打开。历史包含旧秘密及附件，请先升级所有客户端。", "Enabling upgrades the vault format. Old clients cannot open it. History retains old secrets and attachments; update all clients first."))
                Button(enabled = !working, onClick = { run { vault.command("history-enable"); vault.refresh(); load() } }) { Text(t("启用完整历史", "Enable complete history")) }
            }
        } else if (loaded) {
            if (rows.isEmpty()) Text(t("暂无已保存的历史版本。", "No saved versions yet."), color = MaterialTheme.colorScheme.onSurfaceVariant)
            else Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
                Column {
                    rows.forEachIndexed { index, revision ->
                        if (index > 0) HorizontalDivider(Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.outlineVariant)
                        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(java.text.DateFormat.getDateTimeInstance().format(java.util.Date(revision.optLong("capturedAt"))), style = MaterialTheme.typography.titleSmall)
                                Text(revision.optJSONObject("item")?.optString("title") ?: t("已删除", "Deleted"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                TextButton(enabled = !working, onClick = { selected = revision; reveal = false }) { Text(t("查看版本", "View version")) }
                            }
                            OutlinedButton(enabled = !working && revision.optJSONObject("item") != null, onClick = { selected = revision; reveal = false; confirm = "restore" }) { Text(t("恢复", "Restore")) }
                        }
                    }
                }
            }
            if (rows.size < total) TextButton(enabled = !working, onClick = { run { load(true) } }) { Text(t("加载更多", "Load more")) }
            selected?.let { revision ->
                if (confirm == null) LegacySection {
                    Text(t("所选版本", "Selected version"), style = MaterialTheme.typography.titleMedium)
                    Row(verticalAlignment = Alignment.CenterVertically) { Checkbox(reveal, { reveal = it }); Text(t("显示完整内容（含敏感信息）", "Reveal full contents (includes secrets)"), Modifier.weight(1f)) }
                    if (reveal) Text(revision.optJSONObject("item")?.toString(2) ?: "")
                }
            }
            TextButton(enabled = !working, onClick = { confirm = "prune" }) { Text(t("清理旧版本", "Clear older versions"), color = MaterialTheme.colorScheme.error) }
        }
        if (working) LinearProgressIndicator(Modifier.fillMaxWidth())
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
            TextButton(enabled = !working, onClick = close) { Text(t("关闭", "Close")) }
        }
    }
    confirm?.let { operation ->
        AlertDialog(onDismissRequest = { if (!working) confirm = null },
            title = { Text(if (operation == "prune") t("清理旧版本？", "Clear older versions?") else t("恢复这个版本？", "Restore this version?")) },
            text = { Text(if (operation == "prune") t("保留当前内容。个人库清理本机旧版本；对等资料库仅隐藏旧版本，旧内容仍在同步日志中。已有备份不受影响。", "Current contents remain. Personal vaults clear local older versions; peer libraries only hide them and retain their contents in the sync log. Existing backups are unchanged.") else t("当前内容会保留在历史中，并创建一个新的版本。", "Current contents remain in history and a new version is created.")) },
            confirmButton = { Button(enabled = !working, onClick = { run {
                if (operation == "prune") vault.command("history-prune", JSONObject().put("id", id))
                else vault.command("history-restore", JSONObject().put("id", id).put("revisionId", selected!!.getString("id")).put("time", Instant.now().toString()))
                confirm = null; selected = null; reveal = false; vault.refresh(); load()
            } }) { Text(if (operation == "prune") t("清理", "Clear") else t("恢复", "Restore")) } },
            dismissButton = { TextButton(enabled = !working, onClick = { confirm = null }) { Text(t("取消", "Cancel")) } })
    }
}
