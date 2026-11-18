package com.securepass.vault

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Smartphone
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import com.google.zxing.BarcodeFormat
import com.google.zxing.MultiFormatWriter

@Composable
internal fun RelayGroupPanel(vault: VaultRepository, state: RelayUi, t: (String, String) -> String) {
    val relay = vault.relay
    var endpoint by remember { mutableStateOf(state.endpoint) }
    var createExpanded by remember { mutableStateOf(false) }
    var pasteExpanded by remember { mutableStateOf(false) }
    var accessExpanded by remember { mutableStateOf(false) }
    var groupName by remember { mutableStateOf(t("我的设备", "My devices")) }
    var deviceName by remember { mutableStateOf(t("我的手机", "My phone")) }
    var input by remember { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
    var showInvite by remember(state.groupInvite) { mutableStateOf(false) }
    var createPassword by remember { mutableStateOf("") }
    var joinPassword by remember { mutableStateOf("") }
    var savedPassword by remember { mutableStateOf("") }
    var preview by remember { mutableStateOf<RelayInvitationPreview?>(null) }
    var formError by remember { mutableStateOf<String?>(null) }
    fun readInvitation(text: String) {
        preview = null
        try {
            val read = RelayInvitationPreview.read(text)
            preview = read
            joinPassword = read.password
            formError = null
        } catch (_: Exception) { formError = t("邀请无效或已过期，请检查内容。", "Invalid or expired invitation; check the contents.") }
    }
    fun submit(block: () -> Unit) {
        try { block(); formError = null }
        catch (_: Exception) { formError = t("检查服务器地址、组名和密码（8–128 位可打印 ASCII，不含空格）。", "Check the endpoint, group name and password (8–128 printable ASCII characters, no spaces).") }
    }
    var automaticJoin by remember { mutableStateOf(true) }
    var grantManager by remember { mutableStateOf(false) }
    var confirmation by remember { mutableStateOf<String?>(null) }
    var rename by remember { mutableStateOf<RelayMember?>(null) }
    var newName by remember { mutableStateOf("") }
    val manager = state.groupFresh && state.members.any { it.id == state.device && it.manager }
    LaunchedEffect(state.groupInvite) {
        if (state.groupInvite.isNotEmpty()) automaticJoin = state.automaticJoin
    }
    LaunchedEffect(state.creating, state.endpoint, state.draftGroupName, state.draftDeviceName) {
        if (state.creating) {
            endpoint = state.endpoint
            groupName = state.draftGroupName
            deviceName = state.draftDeviceName
        }
    }
    val ready = !state.busy
    if (state.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    formError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    if (state.managed || state.legacy || state.joining || state.invalid) {
        TextButton(onClick = { accessExpanded = !accessExpanded }) { Text(t("服务器访问设置", "Server access settings")) }
        if (accessExpanded || state.invalid) LegacySection {
        Text(t("服务器访问密码", "Server access password"), style = MaterialTheme.typography.titleMedium)
        Text(t("更新密码会保留设备身份与同步。", "Updating this password preserves device identity and sync."))
        RelayPasswordField(savedPassword, { savedPassword = it }, ready, t)
        OutlinedButton(onClick = { submit { validateRelayPassword(savedPassword); relay.updateServerPassword(savedPassword) } }, enabled = ready && savedPassword.isNotEmpty()) {
            Text(t("保存服务器密码", "Save server password"))
        }
        }
    }
    when {
        state.invalid -> {
            Text(t("接入需要重新验证。请先修改服务器密码并保存；原身份保留，缓存名单不可用于授权。", "Access needs revalidation. Update and save the server password; identity is retained and cached membership cannot authorize access."))
            OutlinedButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("清除本机接入", "Clear local access")) }
        }
        state.legacy -> {
            Text(t("现有手动接入仍保留。迁移前请明确清除本机接入；旧令牌需管理员另行撤销。", "Manual access is retained. Clear local access to migrate; ask the administrator to revoke the old token."))
            OutlinedButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("迁移到设备组…", "Migrate to device group…")) }
        }
        state.managed -> {
            Text(t("设备组「", "Device group: ") + state.groupName.ifEmpty { state.group } + t("」", ""), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            OutlinedButton(onClick = relay::refreshGroup, enabled = ready) { Text(t("刷新名单", "Refresh members")) }
            if (!state.groupFresh) Text(t("请刷新并验证名单后管理设备。", "Refresh to verify membership before managing devices."))
            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
                Column {
                    state.members.forEachIndexed { index, member ->
                        if (index > 0) HorizontalDivider(Modifier.padding(start = 56.dp), color = MaterialTheme.colorScheme.outlineVariant)
                        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Surface(shape = MaterialTheme.shapes.medium, color = MaterialTheme.colorScheme.primaryContainer) {
                                Icon(if (member.id == state.device) Icons.Outlined.Smartphone else Icons.Outlined.Devices, contentDescription = null, modifier = Modifier.padding(12.dp).size(24.dp), tint = MaterialTheme.colorScheme.primary)
                            }
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(member.name + if (member.id == state.device) t(" · 这台手机", " · This phone") else "", style = MaterialTheme.typography.titleSmall)
                                Text((if (member.manager) t("管理员", "Manager") else t("成员", "Member")) + " · " +
                                    if (member.online) t("在线", "Online") else t("离线", "Offline"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                if (manager || member.id == state.device) Row {
                                    TextButton(onClick = { rename = member; newName = member.name }, enabled = ready) { Text(t("改名", "Rename")) }
                                    if (manager && member.id != state.device) TextButton(onClick = { confirmation = "remove:${member.id}" }, enabled = ready) { Text(t("移除", "Remove"), color = MaterialTheme.colorScheme.error) }
                                }
                            }
                        }
                    }
                }
            }
            if (!state.mesh) Text(t("加入设备组后，组内设备会自动双向同步；同时修改时以最后修改为准，另一版本保留在版本历史。", "After joining, devices in the group sync both ways; when both change an item, the last change wins and the other version stays in version history."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (manager) {
                Row { Checkbox(automaticJoin, { automaticJoin = it }, enabled = ready && state.groupInvite.isEmpty()); Text(t("确认后免审批加入", "Join without approval after confirmation")) }
                Button(onClick = { grantManager = false; relay.inviteToGroup(automaticJoin) }, enabled = ready) { Text(t("添加设备", "Add device")) }
            }
            if (state.groupFresh && state.groupInvite.isNotEmpty()) {
                GroupQr(state.groupInvite, t("设备组邀请", "Group invitation"))
                Text(if (state.automaticJoin) t("加入后立即与组内设备双向同步全部密码库内容。", "After joining, the whole vault syncs both ways with the group.") else t("需核对配对码并手动批准。", "Compare codes and approve manually."))
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
            Text(t("危险操作", "Danger zone"), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surface) {
                Column(Modifier.fillMaxWidth().padding(16.dp)) {
                    TextButton(onClick = { confirmation = "leave" }, enabled = ready) { Text(t("退出设备组", "Leave device group"), color = MaterialTheme.colorScheme.error) }
                    Text(t("同步记录加密归档并轮换设备 ID；本地资料保留", "Archive encrypted sync history and rotate the device ID; keep local data"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (manager) TextButton(onClick = { confirmation = "disband" }, enabled = ready) { Text(t("解散设备组…", "Disband group…")) }
        }
        state.joining -> {
            Text(t("等待管理设备批准", "Waiting for a managing device to approve"), style = MaterialTheme.typography.headlineSmall)
            Text(if (state.automaticJoin) t("自动加入尚未完成，请刷新状态以继续。", "Automatic joining is incomplete. Refresh the status to continue.") else t("请在邀请你的设备上核对下面的验证码，一致后再点“批准加入”。", "Compare this verification code on the Mac before approving the request."), color = MaterialTheme.colorScheme.onSurfaceVariant)
            SelectionContainer { Text(state.groupCode, style = MaterialTheme.typography.headlineSmall) }
            Button(onClick = relay::finishGroupJoin, enabled = ready) { Text(t("刷新审批状态", "Refresh approval status")) }
            TextButton(onClick = relay::retryGroupJoin, enabled = ready) { Text(t("重新发送申请", "Resend request")) }
            TextButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("停止等待", "Stop waiting")) }
        }
        else -> {
            if (preview == null && !state.creating && !createExpanded) {
                Column(Modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Surface(shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.primaryContainer) {
                        Icon(Icons.Outlined.QrCodeScanner, contentDescription = null, modifier = Modifier.padding(24.dp).size(48.dp), tint = MaterialTheme.colorScheme.primary)
                    }
                    Text(t("加入设备组", "Join device group"), style = MaterialTheme.typography.headlineSmall)
                    Text(t("在已加入的 Mac 上打开「设置 › 同步与设备」点“邀请新设备”，扫描显示的二维码即可加入并开始同步。", "On a Mac already in the group, open Settings › Sync and devices, invite a new device, and scan its QR code to join and start syncing."), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(modifier = Modifier.fillMaxWidth(), onClick = { scanning = true }, enabled = ready) { Text(t("扫描邀请二维码", "Scan invitation QR code")) }
                    TextButton(modifier = Modifier.fillMaxWidth(), onClick = { pasteExpanded = !pasteExpanded }, enabled = ready) { Text(t("粘贴邀请链接", "Paste invitation link")) }
                }
                Text(t("相机权限被拒绝时可改为粘贴链接。中继只转发密文。", "Paste a link if camera permission is denied. The relay only forwards encrypted data."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (pasteExpanded) {
                    Input(t("邀请链接或内容", "Invitation link or contents"), input, { input = it; preview = null }, multiline = true, enabled = ready)
                    Button(onClick = { readInvitation(input) }, enabled = ready && input.isNotBlank()) { Text(t("读取邀请", "Read invitation")) }
                }
                TextButton(enabled = ready, onClick = { createExpanded = true }) { Text(t("高级：创建新设备组", "Advanced: create a new group")) }
            }
            preview?.let { invitation ->
                Text(t("确认邀请", "Confirm invitation"), style = MaterialTheme.typography.titleLarge)
                LegacySection {
                    OutlinedTextField(invitation.endpoint, {}, readOnly = true, label = { Text(t("中继地址", "Relay endpoint")) }, supportingText = { Text(t("来自邀请；以邀请中的地址为准", "Read from the invitation; verify this address")) }, modifier = Modifier.fillMaxWidth())
                    Text(t("设备组由签名邀请绑定，提交后由服务器验证。", "The signed invitation binds the device group; the server verifies it on submission."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    RelayPasswordField(joinPassword, { joinPassword = it }, ready, t)
                    Text(if (invitation.password.isNotEmpty()) t("已从邀请读取组口令，可显示或修改。", "The invitation includes a server password; reveal or edit it if needed.") else t("请向邀请人获取组口令。", "Ask the inviter for the server password."), style = MaterialTheme.typography.bodySmall)
                    Input(t("这台设备的名称", "This device's name"), deviceName, { deviceName = it }, enabled = ready)
                }
                Text(t("加入设备组不代表获得密码库权限。", "Joining does not grant access to vault data."), color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = { preview = null }, enabled = ready) { Text(t("返回", "Back")) }
                    Button(onClick = { submit { validateRelayPassword(joinPassword); require(invitation.input == input.trim()); relay.joinGroup(invitation.input, deviceName, joinPassword) } }, enabled = ready && joinPassword.isNotEmpty() && deviceName.isNotBlank()) { Text(t("请求加入", "Request to join")) }
                }
            }
            if (state.creating || createExpanded) {
                Text(t("创建新设备组", "Create device group"), style = MaterialTheme.typography.titleMedium)
                Input(t("这台设备的名称", "This device's name"), deviceName, { deviceName = it }, enabled = ready && !state.creating)
                Input(t("设备组名称", "Group name"), groupName, { groupName = it }, enabled = ready && !state.creating)
                OutlinedTextField(endpoint, { endpoint = it }, label = { Text(t("服务器地址（必填）", "Server endpoint (required)")) }, placeholder = { Text("wss://host/relay/v1/ws") }, enabled = ready && !state.creating, modifier = Modifier.fillMaxWidth())
                RelayPasswordField(createPassword, { createPassword = it }, ready, t)
                Text(t("服务器密码仅用于访问中继，不是主密码或端到端密钥。", "This password grants relay access; it is not your master password or encryption key."), style = MaterialTheme.typography.bodySmall)
                Button(onClick = { submit { validateRelayEndpoint(endpoint); validateRelayPassword(createPassword); require(groupName.isNotBlank()); relay.createGroup(endpoint, groupName, deviceName, createPassword) } }, enabled = ready && endpoint.isNotBlank() && createPassword.isNotEmpty() && groupName.isNotBlank() && deviceName.isNotBlank()) {
                    Text(if (state.creating) t("重试创建", "Retry creation") else t("创建新设备组", "Create group"))
                }
                if (state.creating) {
                    Text(t("重试使用已保存的原请求。清除草稿不能代替远端退出。", "Retries reuse the saved request. Clearing a draft does not revoke remote access."))
                    TextButton(onClick = { confirmation = "clear" }, enabled = ready) { Text(t("清除本机草稿…", "Clear local draft…")) }
                } else TextButton(onClick = { createExpanded = false }, enabled = ready) { Text(t("返回", "Back")) }
            }
        }
    }
    if (scanning) LiveQrScanner(vault, t, { input = it; scanning = false; readInvitation(it) }, { scanning = false }, rawPayload = true)
    confirmation?.let { operation ->
        AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(when { operation == "leave" -> t("退出设备组？", "Leave device group?"); operation == "disband" -> t("解散设备组？", "Disband device group?"); operation.startsWith("remove:") -> t("移除此设备？", "Remove this device?"); else -> t("停止本机接入？", "Stop local access?") }) },
            text = { Text(when {
                operation == "disband" -> t("撤销全组中继访问；已下载资料无法远程删除。", "Revoke access for every member. Downloaded vault data cannot be remotely erased.")
                operation.startsWith("remove:") -> t("撤销此设备的中继访问。已下载资料无法远程删除。", "Revoke this device's relay access. Downloaded data remains on that device.")
                operation == "clear" -> t("仅取消本机申请或接入，不能撤回已发送的申请，也不能代替服务器撤销。本地资料保留，旧同步记录加密归档，新接入使用新设备 ID。", "Cancel locally only; this cannot withdraw a sent request or revoke remote access. Keep local data, archive sync history and rotate the device ID.")
                else -> t("本机停止中继同步，其他成员继续使用。本地资料保留，旧同步记录加密归档。最后一名管理员需先添加其他管理员或解散。", "Stop local sync and retain data and encrypted sync history. Other members stay connected. The last manager must add another manager or disband.")
            }) }, confirmButton = { TextButton(onClick = {
                confirmation = null
                when { operation == "clear" -> relay.clearLocalGroup(); operation.startsWith("remove:") -> relay.removeGroupMember(operation.removePrefix("remove:")); else -> relay.leaveGroup(operation == "disband") }
            }) { Text(when { operation == "leave" -> t("退出", "Leave"); operation == "disband" -> t("解散", "Disband"); operation.startsWith("remove:") -> t("移除", "Remove"); else -> t("确认", "Confirm") }, color = MaterialTheme.colorScheme.error) } }, dismissButton = { TextButton(onClick = { confirmation = null }) { Text(t("取消", "Cancel")) } })
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

@Composable
private fun RelayPasswordField(value: String, change: (String) -> Unit, enabled: Boolean, t: (String, String) -> String) {
    var visible by remember { mutableStateOf(false) }
    OutlinedTextField(value, change, label = { Text(t("服务器密码（必填）", "Server password (required)")) },
        enabled = enabled, singleLine = true, modifier = Modifier.fillMaxWidth(),
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        trailingIcon = { TextButton(onClick = { visible = !visible }) { Text(if (visible) t("隐藏", "Hide") else t("显示", "Show")) } })
}
