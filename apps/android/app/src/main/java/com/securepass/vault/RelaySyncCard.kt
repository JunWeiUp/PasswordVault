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
        else -> state.sync.phase
    }
    val title = when (phase) {
        RelaySyncPhase.IDLE -> t("等待同步检查", "Waiting for a sync check")
        RelaySyncPhase.REQUESTED -> t("准备同步…", "Preparing to sync…")
        RelaySyncPhase.CONNECTING -> t("正在连接同步服务…", "Connecting to sync service…")
        RelaySyncPhase.CHECKING -> t("正在检查更改与回执…", "Checking changes and receipts…")
        RelaySyncPhase.SENDING -> t("正在发送加密更改…", "Sending encrypted changes…")
        RelaySyncPhase.RECEIVING -> t("正在接收并应用更改…", "Receiving and applying changes…")
        RelaySyncPhase.WAITING_FOR_CAPABILITY -> t("等待安全格式协商", "Waiting for secure format negotiation")
        RelaySyncPhase.CHECKED -> t("已同步", "Up to date")
        RelaySyncPhase.FAILED -> t("同步未完成", "Sync incomplete")
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
                if (state.sync.running && phase != RelaySyncPhase.BLOCKED) {
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
                RelaySyncPhase.BLOCKED -> t("请先加入设备组，或修复已失效的设备接入。", "Join a device group or repair invalid device access first.")
                else -> t("同组设备会自动双向同步。多台设备同时修改同一条时以较新的修改为准，较旧版本可在条目历史中找回。", "Devices in the group sync both ways automatically. When the same entry changes on several devices, the newer edit wins; older versions stay in the entry history.")
            }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            state.error?.let { Text(localized(it), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.error) }
            state.sync.lastSentAt?.let { Text(t("最近投递到中继 · ", "Last relay delivery · ") + time(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            state.sync.lastCheckedAt?.let { Text(t("最近检查 · ", "Last check · ") + time(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            state.lastReceived?.let { Text(t("最近接收并处理 · ", "Last received and processed · ") + time(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(onClick = syncNow, enabled = state.paired && !state.invalid && !state.credentialsBlocked && !state.busy && !state.sync.running, modifier = Modifier.fillMaxWidth()) {
                Text(if (state.sync.running) t("同步中…", "Syncing…") else if (phase == RelaySyncPhase.FAILED) t("重试同步", "Retry sync") else t("立即同步", "Sync now"))
            }
        }
    }
}
