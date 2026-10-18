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
    var endpoint by remember(state.endpoint) { mutableStateOf(state.endpoint) }
    var invitation by remember { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
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
        if (state.paired || state.managed) Text(localized(state.status))
        if (!state.paired) Text(t("先创建或加入设备组，再授权密码库同步。资料在设备间加密传输。", "Create or join a device group, then authorize vault sync. Data travels encrypted between devices."))
        state.error?.let { Text(localized(it), color = MaterialTheme.colorScheme.error) }
        if (importError) Text(t("凭据文件无法读取或过大", "Credential file unreadable or too large"), color = MaterialTheme.colorScheme.error)
        if (state.paired) {
        Text(t("待提交：${state.pending}", "Pending: ${state.pending}"))
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
        Text(t("密码库同步授权", "Authorize vault sync"), style = MaterialTheme.typography.titleMedium)
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
        if (state.paired) OutlinedButton(onClick = { relay.unpair() }) { Text(t("解除绑定", "Unpair")) }
        }
        Text(t("Mac 解锁后才会汇总同步。手机离线编辑保留到主库确认。", "Mac processes sync while unlocked. Offline edits remain until Mac confirms them."))
    }
    if (scanning) LiveQrScanner(vault, t, { invitation = it; scanning = false }, { scanning = false }, rawPayload = true)
}
