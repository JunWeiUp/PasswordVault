package com.securepass.vault

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import org.json.JSONObject

/**
 * Local strength estimate for display only (0 = very weak … 4 = very strong). It agrees with the
 * core audit: anything shorter than 12 characters never rates above "weak".
 */
internal fun passwordStrength(password: String): Int {
    if (password.isEmpty()) return 0
    val length = password.codePointCount(0, password.length)
    if (length < 8) return 0
    if (length < 12) return 1
    val classes = listOf(
        password.any { it.isLowerCase() },
        password.any { it.isUpperCase() },
        password.any { it.isDigit() },
        password.any { !it.isLetterOrDigit() },
    ).count { it }
    var score = 2
    if (length >= 16 || classes >= 3) score = 3
    if ((length >= 20 && classes >= 3) || (length >= 16 && classes == 4)) score = 4
    // Long but repetitive passwords (e.g. "aaaaaaaaaaaaaaaa") do not earn a high score.
    if (password.toSet().size <= length / 3) score = minOf(score, 2)
    return score
}

internal fun strengthLabel(score: Int, t: (String, String) -> String): String =
    when (score.coerceIn(0, 4)) {
        0 -> t("很弱", "Very weak")
        1 -> t("弱", "Weak")
        2 -> t("一般", "Fair")
        3 -> t("强", "Strong")
        else -> t("很强", "Very strong")
    }

internal enum class AccountHealthIssue { WEAK, REUSED, EXPIRED }

/** Picks the most actionable issue from a core `audit` finding, in the list chip's order. */
internal fun healthIssue(finding: JSONObject?): AccountHealthIssue? =
    when {
        finding == null -> null
        finding.optBoolean("weak") -> AccountHealthIssue.WEAK
        finding.optBoolean("reused") -> AccountHealthIssue.REUSED
        finding.optBoolean("expired") -> AccountHealthIssue.EXPIRED
        else -> null
    }

/**
 * Text placed on the clipboard by "Copy details" after a failed save. It deliberately contains only
 * the error kind and non-secret context; no field of the entry is ever included.
 */
internal fun saveFailureDetails(kind: String?, type: String, existing: Boolean, sdk: Int, version: String): String {
    val safeKind = kind?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{1,40}")) } ?: "Unknown"
    val safeType = type.takeIf { it.matches(Regex("[A-Za-z]{1,20}")) } ?: "unknown"
    val safeVersion = version.takeIf { it.matches(Regex("[A-Za-z0-9._+-]{1,40}")) } ?: "unknown"
    return listOf(
        "PasswordVault save failed",
        "error: $safeKind",
        "item type: $safeType",
        "operation: ${if (existing) "update" else "create"}",
        "android sdk: $sdk",
        "app version: $safeVersion",
    ).joinToString("\n")
}

@Composable
internal fun PasswordStrengthBar(password: String, t: (String, String) -> String, modifier: Modifier = Modifier) {
    if (password.isEmpty()) return
    val score = passwordStrength(password)
    val color = when {
        score <= 1 -> MaterialTheme.colorScheme.error
        score == 2 -> Color(0xFFB86A12)
        else -> Color(0xFF2F8F63)
    }
    val label = t("强度：", "Strength: ") + strengthLabel(score, t)
    Row(
        modifier.semantics { contentDescription = t("密码强度 $score/4", "Password strength $score/4") },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for (index in 1..4) Box(
                Modifier.weight(1f).height(4.dp).background(
                    if (index <= score) color else MaterialTheme.colorScheme.outlineVariant,
                    RoundedCornerShape(2.dp),
                )
            )
        }
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun AccountHealthBanner(
    issue: AccountHealthIssue,
    t: (String, String) -> String,
    generate: (() -> Unit)?,
    openHealth: (() -> Unit)?,
) {
    val accent = Color(0xFFB86A12)
    Surface(color = accent.copy(alpha = .1f), shape = RoundedCornerShape(16.dp)) {
        Row(Modifier.fillMaxWidth().padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.Shield, null, tint = accent)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    when (issue) {
                        AccountHealthIssue.WEAK -> t("密码过弱", "Weak password")
                        AccountHealthIssue.REUSED -> t("密码被重复使用", "Reused password")
                        AccountHealthIssue.EXPIRED -> t("密码已超过设置的有效期", "Password is past its validity period")
                    },
                    style = MaterialTheme.typography.titleSmall,
                )
                Text(
                    when (issue) {
                        AccountHealthIssue.WEAK -> t("少于 12 个字符。建议换成生成的长密码。", "Shorter than 12 characters. Use a long generated password instead.")
                        AccountHealthIssue.REUSED -> t("其他账号也在使用相同密码。先在网站修改，再更新这里。", "Another account uses the same password. Change it on the website first, then update it here.")
                        AccountHealthIssue.EXPIRED -> t("先在网站修改密码，再更新这里。", "Change the password on the website first, then update it here.")
                    },
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (generate != null) FilledTonalButton(onClick = generate) { Text(t("生成新密码", "Generate new password")) }
                    if (openHealth != null) TextButton(onClick = openHealth) { Text(t("密码健康", "Password health")) }
                }
            }
        }
    }
}

@Composable
internal fun SaveFailureBanner(
    existing: Boolean,
    t: (String, String) -> String,
    retry: () -> Unit,
    copyDetails: () -> Unit,
    enabled: Boolean = true,
    stale: Boolean = false,
) {
    Surface(color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(16.dp)) {
        Row(Modifier.fillMaxWidth().padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(Icons.Outlined.ErrorOutline, null, tint = MaterialTheme.colorScheme.error)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(t("保存失败，输入已保留", "Could not save; your input is preserved"), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onErrorContainer)
                Text(
                    if (existing) t("加密写入没有完成。原条目没有被改动。", "The encrypted write did not finish. The original entry was not changed.")
                    else t("加密写入没有完成。资料库中没有写入任何内容。", "The encrypted write did not finish. Nothing was written to the vault."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                )
                if (stale) Text(
                    t("此条目已在其他设备修改。请对照新版本后再保存。", "This entry changed on another device. Review the latest version before saving."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = retry, enabled = enabled) { Text(t("重试", "Retry")) }
                    TextButton(onClick = copyDetails) { Text(t("复制详情", "Copy details")) }
                }
            }
        }
    }
}
