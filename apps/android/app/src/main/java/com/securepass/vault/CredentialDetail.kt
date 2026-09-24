package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun EntryDetail(
    item: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    onDelete: () -> Unit,
    restore: () -> Unit,
) {
    val type = item.optString("type")
    val scope = rememberCoroutineScope()
    val writable = vault.canEdit(item)
    val deleted = item.optBoolean("isDeleted")
    var code by remember(item.optString("id")) { mutableStateOf("") }
    var remaining by remember(item.optString("id")) { mutableIntStateOf(0) }
    val period = item.optInt("period", 30).coerceAtLeast(1)
    LaunchedEffect(item.toString()) {
        if (type == "totp")
            while (true) {
                val now = System.currentTimeMillis() / 1000
                remaining = period - (now % period).toInt()
                code =
                    try {
                        vault
                            .command(
                                "totp",
                                JSONObject()
                                    .put("secret", item.optString("secret"))
                                    .put("period", period)
                                    .put("time", now),
                            )
                            .optString("code")
                    } catch (_: Exception) {
                        ""
                    }
                delay(1000)
            }
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Surface(
                color = MaterialTheme.colorScheme.primaryContainer,
                shape = RoundedCornerShape(16.dp),
            ) {
                Icon(
                    when (type) {
                        "totp" -> Icons.Outlined.Timer
                        "crypto" -> Icons.Outlined.AccountBalanceWallet
                        else -> Icons.Outlined.Key
                    },
                    null,
                    Modifier.padding(16.dp).size(28.dp),
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(item.optString("title"), style = MaterialTheme.typography.headlineMedium)
                Text(
                    when (type) {
                        "totp" -> t("动态验证码", "Verification code")
                        "crypto" -> t("钱包凭据", "Wallet credentials")
                        else -> t("登录账号", "Login account")
                    },
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }
        if (!writable)
            Text(
                t("此共享条目为只读。", "This shared entry is read-only."),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        if (deleted)
            Text(t("此条目在回收站中。", "This entry is in Trash."), color = MaterialTheme.colorScheme.error)
        when (type) {
            "password" -> {
                LegacySection {
                    Text(
                        t("账号信息", "Account information"),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    DetailField(t("用户名", "Username"), item.optString("username"), vault, t)
                    HorizontalDivider()
                    DetailField(
                        t("密码", "Password"),
                        item.optString("password"),
                        vault,
                        t,
                        secret = true,
                    )
                    if (item.optInt("passwordDuration") > 0)
                        DetailValue(
                            t("密码有效期", "Password validity"),
                            t(
                                "${item.optInt("passwordDuration")} 天",
                                "${item.optInt("passwordDuration")} days",
                            ),
                        )
                    PasswordHistory(item, vault, t)
                }
                if (item.optString("secret").isNotBlank())
                    LegacySection {
                        Text(
                            t("二次验证", "Two-step verification"),
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        DetailField(
                            t("设置密钥", "Setup key"),
                            item.optString("secret"),
                            vault,
                            t,
                            secret = true,
                        )
                    }
                item.optJSONArray("accounts")?.objects()?.forEachIndexed { index, account ->
                    key(account.optString("id"), index) {
                        LegacySection {
                            Text(
                                t("附加账号 ${index + 1}", "Additional account ${index + 1}"),
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.primary,
                            )
                            if (account.optString("label").isNotBlank())
                                DetailValue(t("用途", "Purpose"), account.optString("label"))
                            DetailField(
                                t("用户名", "Username"),
                                account.optString("username"),
                                vault,
                                t,
                            )
                            HorizontalDivider()
                            DetailField(
                                t("密码", "Password"),
                                account.optString("password"),
                                vault,
                                t,
                                secret = true,
                            )
                            PasswordHistory(account, vault, t)
                        }
                    }
                }
            }
            "totp" -> {
                LegacySection {
                    Text(t("当前验证码", "Current code"), style = MaterialTheme.typography.titleMedium)
                    Text(
                        code.ifEmpty { "—— ——" }.chunked(3).joinToString(" "),
                        style = MaterialTheme.typography.displaySmall,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    LinearProgressIndicator(
                        progress = { if (code.isEmpty()) 0f else remaining.toFloat() / period },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        if (code.isEmpty())
                            t("无法生成，请检查设置密钥", "Could not generate; check the setup key")
                        else t("${remaining} 秒后更新", "Refreshes in ${remaining}s"),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(
                        onClick = { vault.copy(code) },
                        enabled = code.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Outlined.ContentCopy, null, Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(t("复制验证码", "Copy code"))
                    }
                }
                LegacySection {
                    Text(
                        t("验证信息", "Verification information"),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    if (item.optString("username").isNotBlank())
                        DetailField(t("账号", "Account"), item.optString("username"), vault, t)
                    DetailValue(t("更新间隔", "Refresh interval"), t("$period 秒", "$period seconds"))
                    DetailField(
                        t("设置密钥", "Setup key"),
                        item.optString("secret"),
                        vault,
                        t,
                        secret = true,
                    )
                }
            }
            "crypto" -> {
                LegacySection {
                    Text(t("钱包地址", "Wallet address"), style = MaterialTheme.typography.titleMedium)
                    if (item.optString("network").isNotBlank())
                        DetailValue(t("网络", "Network"), item.optString("network"))
                    DetailField(
                        t("地址", "Address"),
                        item.optString("address"),
                        vault,
                        t,
                        monospace = true,
                    )
                }
                if (item.optString("mnemonic").isNotBlank())
                    LegacySection {
                        Text(
                            t("助记词", "Recovery phrase"),
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        DetailField(
                            t("助记词", "Recovery phrase"),
                            item.optString("mnemonic"),
                            vault,
                            t,
                            secret = true,
                            words = true,
                        )
                    }
                if (item.optString("privateKey").isNotBlank())
                    LegacySection {
                        Text(
                            t("私钥详情", "Private key details"),
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        DetailField(
                            t("私钥", "Private key"),
                            item.optString("privateKey"),
                            vault,
                            t,
                            secret = true,
                            monospace = true,
                        )
                    }
            }
        }
        if (
            listOf("category", "url", "email", "sharedVaultId").any {
                item.optString(it).isNotBlank()
            } || entryTags(item).isNotEmpty()
        )
            LegacySection {
                Text(
                    t("基本信息", "Basic information"),
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                if (item.optString("category").isNotBlank())
                    DetailValue(t("分类", "Category"), item.optString("category"))
                if (item.optString("url").isNotBlank())
                    DetailField(t("网站", "Website"), item.optString("url"), vault, t)
                if (item.optString("email").isNotBlank())
                    DetailField(t("邮箱", "Email"), item.optString("email"), vault, t)
                if (item.optString("sharedVaultId").isNotBlank()) {
                    val sharedName =
                        vault.state.value.sharedVaults
                            .firstOrNull { it.optString("id") == item.optString("sharedVaultId") }
                            ?.optString("name")
                            .orEmpty()
                    DetailValue(
                        t("所属资料库", "Vault"),
                        sharedName.ifEmpty { t("共享资料库", "Shared vault") },
                    )
                }
                val tags = entryTags(item)
                if (tags.isNotEmpty()) {
                    Text(
                        t("标签", "Tags"),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        tags.forEach { tag ->
                            Surface(
                                color = MaterialTheme.colorScheme.surfaceVariant,
                                shape = RoundedCornerShape(8.dp),
                            ) {
                                Text(
                                    tag,
                                    Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                                    style = MaterialTheme.typography.labelMedium,
                                )
                            }
                        }
                    }
                }
                if (
                    item.optString("category").isBlank() &&
                        item.optString("url").isBlank() &&
                        tags.isEmpty() &&
                        type != "crypto"
                )
                    Text(
                        t("未设置分类或标签", "No category or tags"),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
            }
        if (item.optString("note").isNotBlank())
            LegacySection {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        t("备注", "Notes"),
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    IconButton(onClick = { vault.copy(item.optString("note")) }) {
                        Icon(Icons.Outlined.ContentCopy, t("复制备注", "Copy notes"))
                    }
                }
                MarkdownNote(item.optString("note"))
            }
        Text(
            t("最近修改 · ", "Updated · ") + noteDate(item),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (writable && !deleted)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(
                    selected = item.optBoolean("isFavorite"),
                    onClick = {
                        scope.launch {
                            vault.save(
                                JSONObject(item.toString())
                                    .put("isFavorite", !item.optBoolean("isFavorite"))
                            )
                        }
                    },
                    label = { Text(t("收藏", "Favorite")) },
                    leadingIcon = { Icon(Icons.Outlined.StarOutline, null, Modifier.size(18.dp)) },
                )
                FilterChip(
                    selected = item.optBoolean("isPinned"),
                    onClick = {
                        scope.launch {
                            vault.save(
                                JSONObject(item.toString())
                                    .put("isPinned", !item.optBoolean("isPinned"))
                            )
                        }
                    },
                    label = { Text(t("置顶", "Pinned")) },
                    leadingIcon = { Icon(Icons.Outlined.PushPin, null, Modifier.size(18.dp)) },
                )
            }
        if (deleted && writable)
            Button(onClick = restore, modifier = Modifier.fillMaxWidth()) {
                Text(t("恢复", "Restore"))
            }
        OutlinedButton(
            enabled = writable && !(deleted && item.optString("sharedVaultId").isNotEmpty()),
            onClick = onDelete,
            modifier = Modifier.fillMaxWidth(),
            colors =
                ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
        ) {
            Icon(Icons.Outlined.DeleteOutline, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(t("删除…", "Delete…"))
        }
    }
}

@Composable
private fun DetailValue(label: String, value: String) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(
            label,
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(value, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun DetailField(
    label: String,
    value: String,
    vault: VaultRepository,
    t: (String, String) -> String,
    secret: Boolean = false,
    monospace: Boolean = false,
    words: Boolean = false,
) {
    var visible by remember(value) { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label,
                Modifier.weight(1f),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (secret)
                IconButton(onClick = { visible = !visible }, enabled = value.isNotEmpty()) {
                    Icon(
                        if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                        if (visible) t("隐藏$label", "Hide $label") else t("显示$label", "Show $label"),
                    )
                }
            IconButton(onClick = { vault.copy(value) }, enabled = value.isNotEmpty()) {
                Icon(Icons.Outlined.ContentCopy, t("复制$label", "Copy $label"))
            }
        }
        if (words && visible) {
            val entries = value.trim().split(Regex("\\s+"))
            entries.chunked(2).forEachIndexed { row, pair ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    pair.forEachIndexed { col, word ->
                        Surface(
                            modifier = Modifier.weight(1f),
                            color = MaterialTheme.colorScheme.surfaceVariant,
                            shape = RoundedCornerShape(8.dp),
                        ) {
                            Text(
                                "${row * 2 + col + 1}. $word",
                                Modifier.padding(10.dp),
                                fontFamily = FontFamily.Monospace,
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        } else
            Text(
                when {
                    value.isEmpty() -> t("未填写", "Not set")
                    secret && !visible -> "••••••••••••"
                    else -> value
                },
                style = MaterialTheme.typography.bodyLarge,
                fontFamily = if (monospace || secret) FontFamily.Monospace else FontFamily.Default,
            )
    }
}

@Composable
internal fun PasswordHistory(
    account: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
) {
    val history = account.optJSONArray("passwordHistory")?.objects().orEmpty()
    if (history.isEmpty()) return
    var expanded by remember { mutableStateOf(false) }
    TextButton(onClick = { expanded = !expanded }) {
        Icon(Icons.Outlined.History, null, Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(
            if (expanded) t("收起密码历史", "Hide password history")
            else t("密码历史（${history.size}）", "Password history (${history.size})")
        )
    }
    if (expanded)
        history.forEachIndexed { index, record ->
            key(index) {
                DetailField(
                    record.optString("changedAt").ifEmpty {
                        t("历史密码 ${index + 1}", "Previous password ${index + 1}")
                    },
                    record.optString("password"),
                    vault,
                    t,
                    secret = true,
                )
            }
        }
}
