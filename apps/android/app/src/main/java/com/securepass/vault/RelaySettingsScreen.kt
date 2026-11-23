package com.securepass.vault

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
internal fun RelaySettingsScreen(vault: VaultRepository, t: (String,String)->String) {
    val relay = vault.relay
    val state by relay.state.collectAsState()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun localized(text: String): String { val parts = text.split(" / ", limit = 2); return if (parts.size == 2) t(parts[0], parts[1]) else text }
    var noteConflicts by remember { mutableStateOf<List<org.json.JSONObject>>(emptyList()) }
    var resolvingId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(state.paired, state.managed, state.busy) {
        if (state.paired || state.managed) noteConflicts = vault.meshConflicts()
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (state.paired || state.managed) {
            RelaySyncCard(state, t, relay::syncNow)
            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.primaryContainer) {
                Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(t("已加入同步组 · L1 元数据优先", "In sync group · L1 metadata-first"), style = MaterialTheme.typography.titleSmall)
                    Text(t("密码、笔记正文与大附件元数据优先毫秒级双向同步；大于 512 KB 的附件不阻塞队列、按需拉取。非重叠章节自动合并，重叠编辑保留并行分支供本机解决。", "Credentials, notes, and metadata for >512 KB attachments sync first without head-of-line blocking; large blobs download on demand. Disjoint edits auto-merge and overlapping edits stay as visible local branches."), style = MaterialTheme.typography.bodyMedium)
                }
            }
            if (noteConflicts.isNotEmpty()) {
                Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.errorContainer) {
                    Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(t("待解决并行分支（${noteConflicts.size} 篇笔记）", "Parallel branches to resolve (${noteConflicts.size})"), style = MaterialTheme.typography.titleSmall)
                        Text(t("两端附件引用已自动取并集保护（0 项丢失），未选用分支保留 30 天。", "Attachments from both branches are union-protected; the unchosen branch stays in history for 30 days."), style = MaterialTheme.typography.bodySmall)
                        noteConflicts.forEach { cf ->
                            val nid = cf.optString("noteId")
                            val busyThis = resolvingId == nid
                            OutlinedCard(Modifier.fillMaxWidth()) {
                                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                    Text(cf.optString("title").ifBlank { t("未命名笔记", "Untitled note") }, style = MaterialTheme.typography.titleSmall)
                                    Text("${t("冲突位置：", "Section: ")}${cf.optString("section")} · ${cf.optString("localDevice")} ↔ ${cf.optString("remoteDevice")}", style = MaterialTheme.typography.bodySmall)
                                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                        OutlinedButton(enabled = !busyThis, onClick = {
                                            resolvingId = nid
                                            scope.launch {
                                                try { if (vault.resolveMeshConflict(nid, "local")) noteConflicts = vault.meshConflicts() }
                                                finally { resolvingId = null }
                                            }
                                        }) { Text(t("保留本机", "Keep local")) }
                                        OutlinedButton(enabled = !busyThis, onClick = {
                                            resolvingId = nid
                                            scope.launch {
                                                try { if (vault.resolveMeshConflict(nid, "remote")) noteConflicts = vault.meshConflicts() }
                                                finally { resolvingId = null }
                                            }
                                        }) { Text(t("采用远端", "Use remote")) }
                                        Button(enabled = !busyThis, onClick = {
                                            resolvingId = nid
                                            scope.launch {
                                                try { if (vault.resolveMeshConflict(nid, "both")) noteConflicts = vault.meshConflicts() }
                                                finally { resolvingId = null }
                                            }
                                        }) { Text(t("合并两版", "Keep both")) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        if (!state.paired && !state.managed) state.error?.let { Text(localized(it), color = MaterialTheme.colorScheme.error) }
        if (state.credentialsBlocked) {
            Text(t("中继凭据由本机主密码保护。迁移失败不会清除原接入。", "Relay credentials are protected by the local master password. Failed migration preserves the original access."))
            Button(onClick = relay::retryCredentials, enabled = !state.busy) { Text(t("重试读取凭据", "Retry credential access")) }
        } else RelayGroupPanel(vault, state, t)
    }
}
