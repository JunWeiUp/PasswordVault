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
    var invitation by remember { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
    var pairingExpanded by remember { mutableStateOf(false) }
    var legacyExpanded by remember { mutableStateOf(false) }
    var showReply by remember(state.reply) { mutableStateOf(false) }
    fun localized(text: String): String { val parts = text.split(" / ", limit = 2); return if (parts.size == 2) t(parts[0], parts[1]) else text }
    var importError by remember { mutableStateOf(false) }
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
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(t("中继同步", "Relay sync"), style = MaterialTheme.typography.headlineSmall)
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
            if (state.reply.isNotEmpty()) SelectionContainer { Text(state.reply) }
        }

        if (state.paired || state.managed) Text(localized(state.status))
        if (!state.paired) Text(t("先创建或加入设备组，再授权密码库同步。资料在设备间加密传输。", "Create or join a device group, then authorize vault sync. Data travels encrypted between devices."))
        state.error?.let { Text(localized(it), color = MaterialTheme.colorScheme.error) }
        if (importError) Text(t("凭据文件无法读取或过大", "Credential file unreadable or too large"), color = MaterialTheme.colorScheme.error)
        if (state.paired) {
        if (state.peerLibrary.isEmpty()) Text(t("待提交：${state.pending}", "Pending: ${state.pending}"))
        else Text(t("本地已保存；中继投递不代表所有设备已应用", "Saved locally; relay delivery does not mean every device has applied it"))
        if (state.conflicts > 0) {
            Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer)) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(t("有 ${state.conflicts} 项合并冲突，请到电脑端处理", "${state.conflicts} merge conflicts — resolve on your computer"), style = MaterialTheme.typography.titleSmall)
                    Text(t("打开 Mac 设置 → 中继同步，逐条选择或统一采用手机端 / Mac 端。处理完成后会自动继续同步，无需反复点击“立即同步”。", "Open Mac Settings → Relay sync. Resolve individually or use the mobile/Mac version for all. Sync resumes automatically; repeatedly tapping Sync now will not resolve conflicts."))
                }
            }
        }
        state.lastReceived?.let { Text(t("最近接收：", "Last received: ") + java.util.Date(it).toString()) }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(onClick = { relay.syncNow() }, enabled = state.paired && !state.invalid && !state.busy) { Text(t("立即同步", "Sync now")) }
            OutlinedButton(onClick = { relay.pause(!state.paused) }, enabled = state.paired && !state.invalid && !state.busy) { Text(if (state.paused) t("恢复", "Resume") else t("暂停", "Pause")) }
        }
        }
        HorizontalDivider()
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
        OutlinedTextField(endpoint, { endpoint = it }, label = { Text("wss://host/relay/v1/ws") }, modifier = Modifier.fillMaxWidth())
        OutlinedButton(onClick = { importer.launch(arrayOf("application/json", "text/plain")) }) { Text(t("导入设备凭据 JSON", "Import credential JSON")) }
        HorizontalDivider()
            }
        }
        HorizontalDivider()
        if (state.legacy || (state.managed && !state.invalid)) {
        if (state.managed) Text(t("在 Mac 的“我的设备”中开启本机的“查看并同步修改”，保持两端解锁即可完成授权。", "Enable View and sync changes for this device in My devices on Mac. Keep both vaults unlocked to finish authorization."))
        TextButton(onClick = { pairingExpanded = !pairingExpanded }) { Text(t("兼容旧版密码库配对", "Legacy vault pairing")) }
        if (pairingExpanded) {
        OutlinedButton(onClick = { scanning = true }) { Text(t("扫描 Mac 配对码", "Scan Mac invitation")) }
        OutlinedTextField(invitation, { invitation = it }, label = { Text(t("或粘贴邀请内容", "Or paste invitation")) }, modifier = Modifier.fillMaxWidth(), maxLines = 5)
        Button(onClick = { relay.pair(invitation); invitation = "" }, enabled = !state.busy && invitation.isNotEmpty()) { Text(t("读取邀请", "Read invitation")) }
        if (state.reply.isNotEmpty()) {
            Text(t("校验码：${state.code}", "Verification: ${state.code}"), style = MaterialTheme.typography.titleLarge)
            Text(t("将以下回执交给 Mac，核对校验码并在 Mac 授权。", "Return this reply to Mac, compare codes and authorize on Mac."))
            val image = remember(state.reply) {
                val matrix = MultiFormatWriter().encode(state.reply, BarcodeFormat.QR_CODE, 400, 400)
                Bitmap.createBitmap(400, 400, Bitmap.Config.ARGB_8888).apply {
                    setPixels(IntArray(400*400) { if (matrix[it%400,it/400]) android.graphics.Color.BLACK else android.graphics.Color.WHITE },0,400,0,0,400,400)
                }.asImageBitmap()
            }
            Image(image, contentDescription = t("配对回执", "Pairing reply"), modifier = Modifier.size(220.dp))
            TextButton(onClick = { showReply = !showReply }) { Text(t("查看配对回执（可复制）", "Show pairing reply")) }
            if (showReply) SelectionContainer { Text(state.reply, style = MaterialTheme.typography.bodySmall) }
        }
        }
        if (state.paired) OutlinedButton(onClick = { relay.unpair() }) { Text(t("解除绑定", "Unpair")) }
        }
        Text(t("Mac 解锁后才会汇总同步。手机离线编辑保留到主库确认。", "Mac processes sync while unlocked. Offline edits remain until Mac confirms them."))
    }
    if (scanning) LiveQrScanner(vault, t, { invitation = it; scanning = false }, { scanning = false }, rawPayload = true)
}
