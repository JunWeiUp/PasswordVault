package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

@Composable
internal fun RelaySyncCard(state: RelayUi, t: (String, String) -> String, syncNow: () -> Unit) {
    fun localized(value: String): String = value.split(" / ", limit = 2).let { if (it.size == 2) t(it[0], it[1]) else value }
    fun time(value: Long): String = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault()).format(java.util.Date(value))
    val phase = when {
        state.invalid || state.credentialsBlocked || !state.paired -> RelaySyncPhase.BLOCKED
        state.paused -> RelaySyncPhase.PAUSED
        else -> state.sync.phase
    }
    val title = when (phase) {
        RelaySyncPhase.IDLE -> t("等待同步检查", "Waiting for a sync check")
        RelaySyncPhase.REQUESTED -> t("准备同步…", "Preparing to sync…")
        RelaySyncPhase.CONNECTING -> t("正在连接同步服务…", "Connecting to sync service…")
        RelaySyncPhase.CHECKING -> t("正在检查更改与回执…", "Checking changes and receipts…")
        RelaySyncPhase.SENDING -> t("正在发送加密更改…", "Sending encrypted changes…")
        RelaySyncPhase.RECEIVING -> t("正在接收并应用更改…", "Receiving and applying changes…")
        RelaySyncPhase.WAITING_FOR_PRIMARY -> t("等待其他设备确认", "Waiting for other devices to confirm")
        RelaySyncPhase.WAITING_FOR_CAPABILITY -> t("等待安全格式协商", "Waiting for secure format negotiation")
        RelaySyncPhase.CHECKED -> if (state.mesh) t("已同步", "Up to date") else t("本轮同步检查完成", "Sync check completed")
        RelaySyncPhase.FAILED -> t("同步未完成", "Sync incomplete")
        RelaySyncPhase.PAUSED -> t("密码库同步已暂停", "Vault sync paused")
        RelaySyncPhase.BLOCKED -> t("同步暂不可用", "Sync unavailable")
    }
    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.Sync, null, tint = MaterialTheme.colorScheme.primary)
                Column(Modifier.weight(1f)) {
                    Text(t("密码库同步", "Vault sync"), style = MaterialTheme.typography.titleMedium)
                    Text(localized(state.status), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Column(Modifier.semantics { liveRegion = LiveRegionMode.Polite }, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, style = MaterialTheme.typography.titleLarge, color = if (phase == RelaySyncPhase.FAILED) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                if (state.peerLibrary.isEmpty() && state.paired && !state.mesh) {
                    Text(if (state.pending > 0) t("${state.pending} 项本地更改等待其他设备确认", "${state.pending} local changes await confirmation from other devices")
                        else t("没有等待确认的本地更改", "No local changes await confirmation"), style = MaterialTheme.typography.bodyMedium)
                }
                if (state.sync.running && phase !in setOf(RelaySyncPhase.PAUSED, RelaySyncPhase.BLOCKED)) {
                    val fraction = state.sync.fraction
                    if (fraction == null) LinearProgressIndicator(Modifier.fillMaxWidth())
                    else {
                        LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                        Text(t("已处理 ${state.sync.completed} / ${state.sync.total} 个传输分段", "Processed ${state.sync.completed} / ${state.sync.total} transfer segments"), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            Text(when (phase) {
                RelaySyncPhase.WAITING_FOR_CAPABILITY -> t("正在核对双方支持的加密格式。请保持两端解锁并更新到兼容版本；本地更改会保留。", "Checking compatible encrypted formats. Keep both vaults unlocked and use compatible versions; local changes are retained.")
                RelaySyncPhase.PAUSED -> t("点击下方“恢复”后继续同步；已保存的本地更改不会丢失。", "Choose Resume below to continue. Saved local changes are retained.")
                RelaySyncPhase.BLOCKED -> t("请先完成密码库授权，或修复已失效的设备接入。", "Complete vault authorization or repair invalid device access first.")
                else -> if (state.mesh) t("同组设备会自动双向同步。多台设备同时修改同一条时以较新的修改为准，较旧版本可在条目历史中找回。", "Devices in the group sync both ways automatically. When the same entry changes on several devices, the newer edit wins; older versions stay in the entry history.")
                    else if (state.peerLibrary.isNotEmpty()) t("本地内容已经保存。加密更改会发送给已授权设备；本轮检查完成不代表所有设备都已接收并应用。", "Your changes are saved locally. Encrypted changes go to authorized devices; a completed check does not mean every device has received and applied them.")
                    else t("本地内容已经保存。等待确认的记录可能包含条目或笔记分类；中继接收后，仍需组内其他设备处理并回传确认。", "Your changes are saved locally. Pending records may include entries or note categories. Relay receipt still requires processing and acknowledgement by another device in the group.")
            }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            state.error?.let { Text(localized(it), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error) }
            if (phase == RelaySyncPhase.WAITING_FOR_PRIMARY) Text(t("请让组内至少一台其他设备在线并解锁。重复点击不会代替它的确认。", "Keep at least one other device in the group online and unlocked. Retrying cannot replace its acknowledgement."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            state.sync.lastSentAt?.let { Text(t("最近投递到中继 · ", "Last relay delivery · ") + time(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            state.sync.lastCheckedAt?.let { Text(t("最近检查 · ", "Last check · ") + time(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            state.lastReceived?.let { Text(t("最近接收并处理 · ", "Last received and processed · ") + time(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(onClick = syncNow, enabled = state.paired && !state.invalid && !state.credentialsBlocked && !state.paused && !state.busy && !state.sync.running, modifier = Modifier.fillMaxWidth()) {
                Text(if (state.sync.running) t("同步中…", "Syncing…") else if (phase == RelaySyncPhase.FAILED) t("重试同步", "Retry sync") else t("立即同步", "Sync now"))
            }
        }
    }
}
