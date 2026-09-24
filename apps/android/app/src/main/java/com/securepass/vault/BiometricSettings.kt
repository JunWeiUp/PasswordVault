package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch

@Composable
internal fun BiometricSettings(
    biometric: BiometricVault,
    vault: VaultRepository,
    t: (String, String) -> String,
) {
    var enabled by remember { mutableStateOf(biometric.enabled) }
    var available by remember { mutableStateOf(biometric.available) }
    var busy by remember { mutableStateOf(false) }
    var confirmDisable by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, biometric) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                enabled = biometric.enabled
                available = biometric.available
            }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    DisposableEffect(biometric) {
        val stop = biometric.observeEnabled { enabled = biometric.enabled }
        onDispose { stop() }
    }
    fun enroll() {
        if (busy) return
        val renewal = enabled
        busy = true
        message = null
        scope.launch {
            try {
                biometric.enroll(vault.biometricKey()) { success ->
                    enabled = biometric.enabled
                    available = biometric.available
                    busy = false
                    message =
                        if (success) {
                            if (renewal) t("生物识别已更新", "Biometric verification updated")
                            else t("生物识别已启用", "Biometric unlock enabled")
                        } else if (enabled)
                            t(
                                "验证未完成，原生物识别设置已保留。",
                                "Verification not completed; the previous setup is preserved.",
                            )
                        else
                            t(
                                "验证未完成，生物识别仍未启用。",
                                "Verification not completed; biometric unlock remains off.",
                            )
                }
            } catch (_: Exception) {
                enabled = biometric.enabled
                busy = false
                message =
                    t(
                        "无法完成设置，请重试；仍可使用主密码。",
                        "Could not complete setup; retry or use your master password.",
                    )
            }
        }
    }
    BiometricControls(
        enabled,
        available,
        busy,
        message,
        t,
        onToggle = { checked -> if (checked) enroll() else confirmDisable = true },
        onRenew = ::enroll,
    )
    if (confirmDisable)
        AlertDialog(
            onDismissRequest = { confirmDisable = false },
            title = { Text(t("关闭生物识别？", "Turn off biometric unlock?")) },
            text = {
                Text(
                    t(
                        "下次解锁需要使用主密码，资料不会被删除。",
                        "Use your master password next time. Your records will be kept.",
                    )
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        biometric.disable()
                        enabled = biometric.enabled
                        confirmDisable = false
                        message =
                            if (!enabled) t("生物识别已关闭", "Biometric unlock disabled")
                            else t("未能关闭，请重试。", "Could not disable; please retry.")
                    }
                ) {
                    Text(t("关闭生物识别", "Turn off biometric unlock"))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmDisable = false }) { Text(t("取消", "Cancel")) }
            },
        )
}

@Composable
internal fun BiometricControls(
    enabled: Boolean,
    available: Boolean,
    busy: Boolean,
    message: String?,
    t: (String, String) -> String,
    onToggle: (Boolean) -> Unit,
    onRenew: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Outlined.Fingerprint, null, tint = MaterialTheme.colorScheme.primary)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(t("生物识别解锁", "Biometric unlock"), style = MaterialTheme.typography.titleMedium)
                Text(
                    if (busy) t("等待验证…", "Awaiting verification…")
                    else if (enabled) t("已开启", "On") else t("未开启", "Off"),
                    style = MaterialTheme.typography.bodyMedium,
                    color =
                        if (enabled) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(
                checked = enabled,
                onCheckedChange = onToggle,
                enabled = !busy && (available || enabled),
                modifier =
                    Modifier.semantics { contentDescription = t("生物识别解锁", "Biometric unlock") },
            )
        }
        if (!available)
            Text(
                t(
                    "生物识别当前不可用，请检查系统指纹设置或稍后重试。",
                    "Biometrics are currently unavailable. Check system settings or try later.",
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        else if (!enabled && !busy)
            Text(
                t(
                    "打开开关并完成系统验证后启用。",
                    "Turn on the switch and complete system verification to enable.",
                ),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
        if (enabled)
            OutlinedButton(onClick = onRenew, enabled = available && !busy) {
                Text(t("更新生物识别验证", "Renew biometric verification"))
            }
        message?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
