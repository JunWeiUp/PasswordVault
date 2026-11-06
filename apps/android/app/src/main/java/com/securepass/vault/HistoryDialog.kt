package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Instant

@Composable
internal fun HistoryDialog(vault: VaultRepository, id: String, t: (String, String) -> String, close: () -> Unit) {
    val scope = rememberCoroutineScope()
    var enabled by remember { mutableStateOf(false) }
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
    }
    val run: (suspend () -> Unit) -> Unit = { action -> if (!working) { working = true; message = null; scope.launch { try { action() } catch (_: Exception) { message = t("操作失败，请先保存草稿并检查权限。", "Operation failed. Save pending drafts and check permissions.") } finally { working = false } } } }
    LaunchedEffect(id) { run { load() } }
    AlertDialog(onDismissRequest = { if (!working) close() }, title = { Text(t("版本历史", "Version history")) }, text = {
        Column(Modifier.heightIn(max = 500.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (!enabled) {
                Text(t("启用将升级资料库格式，旧客户端无法打开。历史包含旧秘密及附件，请先升级所有客户端。", "Enabling upgrades the vault format. Old clients cannot open it. History retains old secrets and attachments; update all clients first."))
                Button(enabled = !working, onClick = { run { vault.command("history-enable"); vault.refresh(); load() } }) { Text(t("启用完整历史", "Enable complete history")) }
            } else {
                rows.forEach { revision -> TextButton(enabled = !working, onClick = { selected = revision; reveal = false }) { Text(Instant.ofEpochMilli(revision.optLong("capturedAt")).toString() + " · " + (revision.optJSONObject("item")?.optString("title") ?: t("已删除", "Deleted"))) } }
                if (rows.size < total) TextButton(enabled = !working, onClick = { run { load(true) } }) { Text(t("加载更多", "Load more")) }
                selected?.let { revision ->
                    Row { Checkbox(reveal, { reveal = it }); Text(t("显示完整内容（含敏感信息）", "Reveal full contents (includes secrets)")) }
                    if (reveal) Text(revision.optJSONObject("item")?.toString(2) ?: "")
                    Button(enabled = !working && revision.optJSONObject("item") != null, onClick = { confirm = "restore" }) { Text(t("恢复此版本", "Restore this version")) }
                }
                TextButton(enabled = !working, onClick = { confirm = "prune" }) { Text(t("清理旧版本", "Clear older versions")) }
                if (confirm != null) {
                    Text(if (confirm == "prune") t("保留当前内容。个人库清理本机旧版本；对等资料库仅隐藏旧版本，旧内容仍在同步日志中。已有备份不受影响。", "Current contents remain. Personal vaults clear local older versions; peer libraries only hide them and retain their contents in the sync log. Existing backups are unchanged.") else t("恢复将创建新版本，当前内容保留在历史中。", "Restore creates a new version and retains current contents in history."))
                    Button(enabled = !working, onClick = { val action = confirm; confirm = null; run {
                        if (action == "prune") vault.command("history-prune", JSONObject().put("id", id))
                        else vault.command("history-restore", JSONObject().put("id", id).put("revisionId", selected!!.getString("id")).put("time", Instant.now().toString()))
                        selected = null; reveal = false; vault.refresh(); load()
                    } }) { Text(t("确认", "Confirm")) }
                    TextButton(onClick = { confirm = null }) { Text(t("取消", "Cancel")) }
                }
            }
            if (working) CircularProgressIndicator()
            message?.let { Text(it) }
        }
    }, confirmButton = { TextButton(enabled = !working, onClick = close) { Text(t("关闭", "Close")) } })
}
