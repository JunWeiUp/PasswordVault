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
    var peerInput by remember { mutableStateOf("") }
    var peerRole by remember { mutableStateOf("editor") }
    var familyName by remember { mutableStateOf("") }
    var confirmPersonalSync by remember { mutableStateOf(false) }
    var peerExpanded by remember { mutableStateOf(false) }
    var endpoint by remember(state.endpoint) { mutableStateOf(state.endpoint) }
    var legacyExpanded by remember { mutableStateOf(false) }
    var showPeerReply by remember(state.reply) { mutableStateOf(false) }
    fun localized(text: String): String { val parts = text.split(" / ", limit = 2); return if (parts.size == 2) t(parts[0], parts[1]) else text }
    var importError by remember { mutableStateOf(false) }
    var noteConflicts by remember { mutableStateOf<List<org.json.JSONObject>>(emptyList()) }
    var resolvingId by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(state.paired, state.managed, state.busy) {
        if (state.paired || state.managed) noteConflicts = vault.meshConflicts()
    }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                val text = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)!!.use { stream ->
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(4096)
                        while (true) { val count = stream.read(buffer); if (count < 0) break; require(output.size() + count <= 16384); output.write(buffer, 0, count) }
                        output.toString(Charsets.UTF_8.name())
                    }
                }
                relay.importCredential(text, endpoint)
            } catch (_: Exception) { importError = true }
        }
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
        if (importError) Text(t("凭据文件无法读取或过大", "Credential file unreadable or too large"), color = MaterialTheme.colorScheme.error)
        if (state.credentialsBlocked) {
            Text(t("中继凭据由本机主密码保护。迁移失败不会清除原接入。", "Relay credentials are protected by the local master password. Failed migration preserves the original access."))
            Button(onClick = relay::retryCredentials, enabled = !state.busy) { Text(t("重试读取凭据", "Retry credential access")) }
        } else RelayGroupPanel(vault, state, t)
        if (!state.credentialsBlocked && (state.legacy || (!state.managed && !state.joining && !state.creating))) {
            TextButton(onClick = { legacyExpanded = !legacyExpanded }, enabled = !state.busy) { Text(t("兼容旧版手动接入", "Legacy manual access")) }
            if (legacyExpanded) {
        Text(t("登记设备", "Register device"), style = MaterialTheme.typography.titleMedium)
        Text(t("管理员用此公钥登记设备，并使用与 Mac 相同的设备组。", "Register this public key in the Mac's device group."))
        SelectionContainer { Text("Device: ${state.device}\nGroup: ${state.group}\nPublic key: ${state.publicKey}") }
        OutlinedTextField(endpoint, { endpoint = it }, label = { Text("wss://host/v2/ws") }, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = { importer.launch(arrayOf("application/json", "text/plain")) }) { Text(t("导入设备凭据 JSON", "Import credential JSON")) }
        HorizontalDivider()
            }
        }
        HorizontalDivider()
        TextButton(onClick = { peerExpanded = !peerExpanded }) { Text(t("对等密码库（无需 Mac 在线）", "Peer library (Mac can be offline)")) }
        if (peerExpanded) {
            Text(t("显式升级会保留旧同步日志。请先升级所有参与设备，并独立核对邀请来源和身份回执。", "Enrollment preserves the legacy journal. Update every participating device and independently verify invitation sources and identities."))
            val libraries=runCatching {org.json.JSONArray(state.peerLibraries)}.getOrDefault(org.json.JSONArray())
            if(libraries.length()>0) {
                Text(t("当前资料库：","Current library: ")+state.activePeerLibrary.ifEmpty {t("个人资料库","Personal library")})
                TextButton(onClick={relay.switchPeerLibrary("")}) {Text(t("个人资料库","Personal library"))}
                for(index in 0 until libraries.length()) {
                    val library=libraries.getJSONObject(index)
                    if(!library.optBoolean("personal") && !library.getString("id").startsWith("pending-")) TextButton(onClick={relay.switchPeerLibrary(library.getString("id"))}) {Text(library.optString("name",library.getString("id")))}
                }
            }
            OutlinedTextField(value=familyName,onValueChange={familyName=it},label={Text(t("家庭库名称","Family library name"))})
            Button(onClick={relay.createPeerLibrary(false,familyName)},enabled=familyName.isNotBlank() && state.group.isNotEmpty()) {Text(t("创建独立家庭库","Create independent family library"))}
            val personalInvitation=runCatching {org.json.JSONObject(peerInput).opt("personal")==true}.getOrDefault(false)
            Text(t("加入范围由邀请绑定；家庭库不会合并本机个人资料。","The invitation binds its scope; family libraries never merge local personal records."))
            if(personalInvitation) Row {Checkbox(checked=confirmPersonalSync,onCheckedChange={confirmPersonalSync=it});Text(t("我确认：本机全部个人资料将同步给已授权设备","I confirm: all local personal records will sync to authorized devices"))}
            if(state.peerPending) TextButton(onClick={confirmPersonalSync=false;relay.cancelPeerJoin()}) {Text(t("取消加入，保留本机资料","Cancel enrollment; keep local records"))}
            if (state.peerLibrary.isEmpty()) {
                Button(onClick = { relay.createPeerLibrary() }, enabled = state.group.isNotEmpty()) { Text(t("创建并迁移为对等库", "Create peer library and migrate")) }
            } else {
                SelectionContainer { Text(state.peerLibrary) }
                TextButton(onClick={relay.rekeyPeerLibrary()},enabled=state.group.isNotEmpty() && state.peerRole == "admin" && (state.peerFrozen || state.peerDevice != state.device)) {Text(t("恢复为新共享库（重新邀请成员）","Re-establish as a new shared library"))}
            }
            OutlinedTextField(value = peerInput, onValueChange = { peerInput = it; confirmPersonalSync = false }, enabled = !state.peerPending, label = { Text(t("对等库邀请或身份回执", "Peer invitation or identity request")) }, modifier = Modifier.fillMaxWidth())
            if (!state.peerPending) {
                Button(onClick = { relay.preparePeerJoin(peerInput, confirmPersonalSync) }, enabled = peerInput.isNotEmpty() && state.group.isNotEmpty() && (!personalInvitation || confirmPersonalSync)) { Text(t("确认邀请来源并加入", "Verify invitation source and join")) }
            }
            if(state.peerLibrary.isNotEmpty() && !state.peerPending) {
                Row {
                    listOf("editor" to t("可编辑", "Editor"), "reader" to t("只读", "Reader"), "admin" to t("管理员", "Admin")).forEach { (role, label) ->
                        FilterChip(selected = peerRole == role, onClick = { peerRole = role }, enabled = state.peerRole == "admin" && !state.peerFrozen, label = { Text(label) })
                    }
                }
                Button(onClick = { relay.authorizePeerRequest(peerInput, peerRole) }, enabled = peerInput.isNotEmpty() && state.peerRole == "admin" && !state.peerFrozen) { Text(t("已核对对方身份，授权", "Identity verified, authorize")) }
                val conflicts = runCatching { org.json.JSONObject(state.peerConflicts) }.getOrDefault(org.json.JSONObject())
                for (key in conflicts.keys().asSequence().toList()) {
                    Text(t("并发修改：", "Concurrent changes: ") + key)
                    val versions = conflicts.getJSONArray(key)
                    for (index in 0 until versions.length()) {
                        val operation = versions.getJSONObject(index); val value = operation.get("value")
                        TextButton(onClick = { relay.resolvePeer(key, value) }, enabled = state.peerRole in listOf("admin","editor") && !state.peerFrozen) { Text((value as? org.json.JSONObject)?.optString("title").orEmpty().ifEmpty { t("删除 / 空值", "Delete / empty value") } + " — " + operation.optString("author")) }
                    }
                }
            }
            if (state.reply.isNotEmpty()) {
                TextButton(onClick = { showPeerReply = !showPeerReply }) { Text(if (showPeerReply) t("隐藏身份回执", "Hide identity reply") else t("查看身份回执（可复制）", "Show identity reply")) }
                if (showPeerReply) SelectionContainer { Text(state.reply, style = MaterialTheme.typography.bodySmall) }
            }
        }

    }
}
