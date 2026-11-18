package com.securepass.vault

import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * Device-local display preferences (SharedPreferences "ui"). They are not vault data and never sync;
 * the keys mirror the desktop client's local `clipboardSeconds` preference.
 */
internal object AppPreferences {
    const val FILE = "ui"
    const val CLIPBOARD_SECONDS = "clipboardSeconds"
    const val START_PAGE = "startPage"
    const val LAST_PAGE = "lastPage"
    const val DEFAULT_CLIPBOARD_SECONDS = 30
    /** 0 means "never clear automatically" (the clipboard is still cleared on lock). */
    val CLIPBOARD_CHOICES = listOf(15, 30, 60, 120, 0)
    /** "last" reopens the previous bottom destination; the rest are bottom destinations. */
    val START_CHOICES = listOf("last", "secureNote", "password", "totp", "wallets")
    const val DEFAULT_START = "secureNote"
    const val RELEASES_URL = "https://github.com/JunWeiUp/PasswordVault/releases"

    fun normalizeClipboardSeconds(value: Int): Int = if (value in CLIPBOARD_CHOICES) value else DEFAULT_CLIPBOARD_SECONDS

    fun resolveStartPage(choice: String?, last: String?): String {
        val selected = choice?.takeIf { it in START_CHOICES } ?: DEFAULT_START
        if (selected != "last") return selected
        return last?.takeIf { it in START_CHOICES && it != "last" } ?: DEFAULT_START
    }

    fun clipboardSeconds(context: Context): Int =
        normalizeClipboardSeconds(context.getSharedPreferences(FILE, 0).getInt(CLIPBOARD_SECONDS, DEFAULT_CLIPBOARD_SECONDS))

    fun startPage(context: Context): String {
        val prefs = context.getSharedPreferences(FILE, 0)
        return resolveStartPage(prefs.getString(START_PAGE, null), prefs.getString(LAST_PAGE, null))
    }

    fun rememberLastPage(context: Context, page: String) {
        if (page in START_CHOICES && page != "last") context.getSharedPreferences(FILE, 0).edit().putString(LAST_PAGE, page).apply()
    }

    fun clipboardLabel(seconds: Int, t: (String, String) -> String): String =
        when (seconds) {
            0 -> t("从不", "Never")
            60 -> t("1 分钟", "1 minute")
            120 -> t("2 分钟", "2 minutes")
            else -> t("$seconds 秒", "$seconds seconds")
        }

    fun copiedNotice(seconds: Int): String =
        when (seconds) {
            0 -> "已复制，锁定时清除 / Copied; clears when locked"
            60 -> "已复制，1 分钟后清除 / Copied; clears in 1 minute"
            120 -> "已复制，2 分钟后清除 / Copied; clears in 2 minutes"
            else -> "已复制，$seconds 秒后清除 / Copied; clears in $seconds seconds"
        }

    fun startLabel(choice: String, t: (String, String) -> String): String =
        when (choice) {
            "last" -> t("上次的位置", "Last location")
            "password" -> t("账号", "Accounts")
            "totp" -> t("验证码", "Codes")
            "wallets" -> t("钱包", "Wallets")
            else -> t("笔记", "Notes")
        }
}

/**
 * Offline only when a sync group (or legacy relay) is configured and the transport failed. A retry in
 * progress after a failure still counts as offline so the banner does not flicker between attempts.
 */
internal fun relayOffline(relay: RelayUi): Boolean {
    if (!(relay.managed || relay.legacy || relay.mesh) || relay.credentialsBlocked) return false
    return relay.sync.phase == RelaySyncPhase.FAILED || (relay.sync.phase == RelaySyncPhase.CONNECTING && relay.error != null)
}

@Composable
internal fun OfflineBanner(t: (String, String) -> String, modifier: Modifier = Modifier) {
    Surface(modifier, color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(14.dp)) {
        Row(Modifier.fillMaxWidth().padding(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(Icons.Outlined.CloudOff, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(22.dp))
            Column {
                Text(t("离线 · 修改先加密保存在本机", "Offline · Changes are encrypted and kept on this device"), style = MaterialTheme.typography.titleSmall)
                Text(t("恢复连接后自动与组内设备同步。", "They sync with your group's devices once the connection returns."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}

/** Bundled license texts: PasswordVault, Android dependencies, shared notices and the note editor. */
internal val LICENSE_ASSETS = listOf("LICENSE.txt", "android-third-party-notices.txt", "THIRD_PARTY_NOTICES.md", "NoteEditor-LICENSES.txt")

@Composable
internal fun LicensesDialog(t: (String, String) -> String, close: () -> Unit) {
    val context = LocalContext.current
    val paragraphs = remember {
        LICENSE_ASSETS.flatMap { name ->
            val text = runCatching { context.assets.open(name).bufferedReader().use { it.readText() } }.getOrNull() ?: return@flatMap emptyList()
            listOf("── $name ──") + text.split(Regex("\\n\\s*\\n")).map { it.trim() }.filter { it.isNotEmpty() }
        }
    }
    Dialog(onDismissRequest = close, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Text(t("开源许可", "Open-source licenses"), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = close) { Text(t("关闭", "Close")) }
                }
                LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(paragraphs) { paragraph ->
                        Text(paragraph, fontFamily = if (paragraph.startsWith("──")) FontFamily.Default else FontFamily.Monospace, fontSize = if (paragraph.startsWith("──")) 15.sp else 12.sp)
                    }
                }
            }
        }
    }
}
