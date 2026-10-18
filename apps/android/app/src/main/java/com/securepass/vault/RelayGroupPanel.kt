package com.securepass.vault

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter

@Composable
internal fun RelayGroupPanel(vault: VaultRepository, state: RelayUi, t: (String, String) -> String) {
    val relay = vault.relay
    var endpoint by remember { mutableStateOf(state.endpoint.ifEmpty { "wss://eglish.top/relay/v1/ws" }) }
    var groupName by remember { mutableStateOf(t("我的设备", "My devices")) }
    var deviceName by remember { mutableStateOf(t("我的手机", "My phone")) }
    var input by remember { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
    var showInvite by remember(state.groupInvite) { mutableStateOf(false) }
    var advanced by remember { mutableStateOf(false) }
    var automaticJoin by remember { mutableStateOf(true) }
    var grantManager by remember { mutableStateOf(false) }
    var confirmation by remember { mutableStateOf<String?>(null) }
    var rename by remember { mutableStateOf<RelayMember?>(null) }
    var newName by remember { mutableStateOf("") }
    val manager = state.groupFresh && state.members.any { it.id == state.device && it.manager }
    LaunchedEffect(state.groupInvite) {
        if (state.groupInvite.isNotEmpty()) automaticJoin = state.automaticJoin
    }
    val ready = !state.busy
    Text(t("设备组", "Device group"), style = MaterialTheme.typography.titleLarge)
    Text(t("安全接入后，仍需 Mac 单独授权密码库同步。", "Joining a group requires separate Mac authorization to sync vault data."))
    if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    when {
        state.invalid -> {
            Text(t("接入已失效，缓存名单不可用于授权。", "Access invalid; cached membership is hidden."))
            OutlinedButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("清除本机接入", "Clear local access")) }
        }
        state.legacy -> {
            Text(t("现有手动接入仍保留。迁移前请明确清除本机接入；旧令牌需管理员另行撤销。", "Manual access is retained. Clear local access to migrate; ask the administrator to revoke the old token."))
            OutlinedButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("迁移到设备组…", "Migrate to device group…")) }
        }
        state.managed -> {
            Text(state.groupName.ifEmpty { state.group }, style = MaterialTheme.typography.titleMedium)
            OutlinedButton(onClick = relay::refreshGroup, enabled = ready) { Text(t("刷新名单", "Refresh members")) }
            if (!state.groupFresh) Text(t("请刷新并验证名单后管理设备。", "Refresh to verify membership before managing devices."))
            state.members.forEach { member ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(member.name + if (member.id == state.device) t(" · 本机", " · This device") else "")
                        Text((if (member.manager) t("管理员", "Manager") else t("成员", "Member")) + " · " +
                            if (member.online) t("在线", "Online") else t("离线", "Offline"), style = MaterialTheme.typography.bodySmall)
                        if (manager || member.id == state.device) Row {
                            TextButton(onClick = { rename = member; newName = member.name }, enabled = ready) { Text(t("改名", "Rename")) }
                            if (manager && member.id != state.device) TextButton(onClick = { confirmation = "remove:${member.id}" }, enabled = ready) { Text(t("移除", "Remove")) }
                        }
                    }
                }
            }
            if (manager) {
                Row { Checkbox(automaticJoin, { automaticJoin = it }, enabled = ready && state.groupInvite.isEmpty()); Text(t("扫描后自动加入", "Join automatically after scanning")) }
                Button(onClick = { grantManager = false; relay.inviteToGroup(automaticJoin) }, enabled = ready) { Text(t("添加设备", "Add device")) }
            }
            if (state.groupFresh && state.groupInvite.isNotEmpty()) {
                GroupQr(state.groupInvite, t("设备组邀请", "Group invitation"))
                Text(if (state.automaticJoin) t("扫描即可加入普通成员；密码库需另行授权。", "Scan to join as a member; vault access requires separate authorization.") else t("需核对配对码并手动批准。", "Compare codes and approve manually."))
                Text(t("10 分钟内有效，仅一台设备可认领。请通过可信渠道传递。", "Valid for 10 minutes and one device. Share through a trusted channel."))
                TextButton(onClick = { showInvite = !showInvite }) { Text(t("查看邀请内容（可复制）", "Show invitation text")) }
                if (showInvite) SelectionContainer { Text(state.groupInvite, style = MaterialTheme.typography.bodySmall) }
                if (!state.automaticJoin) OutlinedButton(onClick = relay::checkGroupRequest, enabled = ready) { Text(t("查看加入申请", "Check join request")) }
                TextButton(onClick = relay::cancelGroupInvitation, enabled = ready) { Text(t("取消邀请", "Cancel invitation")) }
            }
            if (state.groupFresh && !state.automaticJoin && state.applicant.isNotEmpty()) {
                Text(t("申请设备：", "Applicant: ") + state.applicant)
                SelectionContainer { Text(state.groupCode, style = MaterialTheme.typography.headlineSmall) }
                Row { Checkbox(grantManager, { grantManager = it }, enabled = ready); Text(t("授予设备组管理权限", "Grant group management")) }
                Button(onClick = { relay.approveGroupRequest(grantManager) }, enabled = ready) { Text(t("两端配对码一致，批准", "Codes match, approve")) }
            }
            TextButton(onClick = { confirmation = "leave" }, enabled = ready) { Text(t("退出设备组…", "Leave group…")) }
            if (manager) TextButton(onClick = { confirmation = "disband" }, enabled = ready) { Text(t("解散设备组…", "Disband group…")) }
        }
        state.joining -> {
            Text(if (state.automaticJoin) t("自动加入尚未完成，请重试。", "Automatic join is incomplete. Retry to continue.") else t("请邀请方核对配对码并批准，再完成加入。", "Ask the inviter to compare this code and approve."))
            SelectionContainer { Text(state.groupCode, style = MaterialTheme.typography.headlineSmall) }
            Button(onClick = relay::finishGroupJoin, enabled = ready) { Text(t("完成加入", "Finish joining")) }
            TextButton(onClick = relay::retryGroupJoin, enabled = ready) { Text(t("重新发送申请", "Resend request")) }
            TextButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("放弃本机申请…", "Abandon local request…")) }
        }
        else -> {
            OutlinedTextField(deviceName, { deviceName = it }, label = { Text(t("本机名称", "Device name")) }, enabled = ready, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(groupName, { groupName = it }, label = { Text(t("设备组名称", "Group name")) }, enabled = ready, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = { advanced = !advanced }, enabled = ready) { Text(t("服务地址", "Relay endpoint")) }
            if (advanced) OutlinedTextField(endpoint, { endpoint = it }, label = { Text("wss://host/relay/v1/ws") }, enabled = ready && !state.creating, modifier = Modifier.fillMaxWidth())
            Button(onClick = { relay.createGroup(endpoint, groupName, deviceName) }, enabled = ready && groupName.isNotBlank() && deviceName.isNotBlank()) {
                Text(if (state.creating) t("重试创建", "Retry creation") else t("创建新设备组", "Create group"))
            }
            if (state.creating) {
                Text(t("重试使用已保存的原请求。清除草稿不能代替远端退出。", "Retries reuse the saved request. Clearing a draft does not revoke remote access."))
                TextButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("清除本机草稿…", "Clear local draft…")) }
            } else {
                HorizontalDivider()
                Text(t("加入已有设备组", "Join an existing group"), style = MaterialTheme.typography.titleMedium)
                OutlinedButton(onClick = { scanning = true }, enabled = ready) { Text(t("扫描设备组邀请", "Scan group invitation")) }
                OutlinedTextField(input, { input = it }, label = { Text(t("或粘贴邀请内容", "Or paste invitation")) }, enabled = ready, modifier = Modifier.fillMaxWidth(), maxLines = 4)
                Button(onClick = { relay.joinGroup(input, deviceName) }, enabled = ready && input.isNotBlank() && deviceName.isNotBlank()) { Text(t("提交加入申请", "Request to join")) }
            }
        }
    }
    if (scanning) LiveQrScanner(vault, t, { input = it; scanning = false; relay.joinGroup(it, deviceName) }, { scanning = false }, rawPayload = true)
    confirmation?.let { operation ->
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(t("确认设备组操作", "Confirm group action")) },
            text = { Text(when {
                operation == "disband" -> t("撤销全组中继访问；已下载资料无法远程删除。", "Revoke access for every member. Downloaded vault data cannot be remotely erased.")
                operation.startsWith("remove:") -> t("撤销此设备的中继访问。已下载资料无法远程删除。", "Revoke this device's relay access. Downloaded data remains on that device.")
                operation == "clear" -> t("仅清除本机接入，不能代替服务器撤销。本地资料保留，旧同步记录加密归档，新接入使用新设备 ID。", "Clear local access only; this does not revoke remote access. Keep local data, archive sync history and rotate the device ID.")
                else -> t("本机停止中继同步，其他成员继续使用。本地资料保留，旧同步记录加密归档。最后一名管理员需先添加其他管理员或解散。", "Stop local sync and retain data and encrypted sync history. Other members stay connected. The last manager must add another manager or disband.")
            }) }, confirmButton = { TextButton(onClick = {
                confirmation = null
                when { operation == "clear" -> relay.clearLocalGroup(); operation.startsWith("remove:") -> relay.removeGroupMember(operation.removePrefix("remove:")); else -> relay.leaveGroup(operation == "disband") }
            }) { Text(t("确认", "Confirm")) } }, dismissButton = { TextButton(onClick = { confirmation = null }) { Text(t("取消", "Cancel")) } })
    }
    rename?.let { member ->
        AlertDialog(onDismissRequest = { rename = null }, title = { Text(t("设备名称", "Device name")) },
            text = { OutlinedTextField(newName, { newName = it }) },
            confirmButton = { TextButton(onClick = { relay.renameGroupMember(member.id, newName); rename = null }, enabled = newName.isNotBlank()) { Text(t("保存", "Save")) } },
            dismissButton = { TextButton(onClick = { rename = null }) { Text(t("取消", "Cancel")) } })
    }
}

@Composable
private fun GroupQr(text: String, label: String) {
    val image = remember(text) { runCatching {
        val matrix = MultiFormatWriter().encode(text, BarcodeFormat.QR_CODE, 400, 400)
        Bitmap.createBitmap(400, 400, Bitmap.Config.ARGB_8888).apply {
            setPixels(IntArray(400*400) { if (matrix[it%400,it/400]) android.graphics.Color.BLACK else android.graphics.Color.WHITE },0,400,0,0,400,400)
        }.asImageBitmap()
    }.getOrNull() }
    if (image != null) Image(image, contentDescription = label, modifier = Modifier.size(220.dp))
}
