package com.securepass.vault

import androidx.compose.foundation.background
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
    DetailPrivacy(vault, item.optString("id")) {
        EntryDetailContent(item, vault, t, onDelete, restore)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun EntryDetailContent(
    item: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    onDelete: () -> Unit,
    restore: () -> Unit,
) {
    val state by vault.state.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val type = item.optString("type")
    val copy = LocalDetailCopy.current ?: vault::copy
    var history by remember(item.optString("id")) { mutableStateOf(false) }
    if (history) HistoryDialog(vault, item.getString("id"), t) { history = false }
    val writable = vault.canEdit(item)
    val deleted = item.optBoolean("isDeleted")
    var code by remember(item.optString("id")) { mutableStateOf("") }
    var nextCode by remember(item.optString("id"), item.optString("secret"), item.optInt("period", 30)) { mutableStateOf("") }
    var remaining by remember(item.optString("id")) { mutableIntStateOf(0) }
    val period = item.optInt("period", 30).coerceAtLeast(1)
    LaunchedEffect(item.toString()) {
        if (type == "totp" || (type == "password" && item.optString("secret").isNotBlank()))
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
                if (type == "totp" && (nextCode.isEmpty() || remaining == period)) {
                    nextCode = try { vault.command("totp", JSONObject().put("secret", item.optString("secret")).put("period", period).put("time", now + period)).optString("code") } catch (_: Exception) { "" }
                }
                delay(1000)
            }
    }
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 11.dp).padding(top = 8.dp, bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (deleted) DetailGroup {
            Text(t("已在回收站", "In Trash"), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.primary)
            Text(t("只读查看。恢复后可继续编辑。", "Read-only. Restore to edit again."), Modifier.padding(horizontal = 16.dp))
            Row(Modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(onClick = restore, enabled = writable) { Text(t("恢复", "Restore")) }
                TextButton(onClick = onDelete, enabled = writable && item.optString("sharedVaultId").isEmpty(), colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error)) { Text(t("永久删除", "Delete permanently")) }
            }
        }
        DetailHero(item, t)
        if (!writable) Text(t("此共享条目为只读。", "This shared entry is read-only."), Modifier.padding(horizontal = 5.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
        when (type) {
            "device" -> DeviceDetailContent(item, vault, t)
            "password" -> {
                if (!deleted) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Button(onClick = { copy(item.optString("password")) }, enabled = item.optString("password").isNotEmpty(), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)) {
                        Icon(Icons.Outlined.ContentCopy, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text(t("复制密码", "Copy password"))
                    }
                    OutlinedButton(onClick = { copy(item.optString("username")) }, enabled = item.optString("username").isNotEmpty(), contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp)) { Text(t("复制用户名", "Copy username")) }
                    if (item.optString("url").isNotBlank()) {
                        val rawUrl = item.optString("url").trim().lineSequence().firstOrNull().orEmpty()
                        val uri = android.net.Uri.parse(if ("://" in rawUrl) rawUrl else "https://$rawUrl")
                        OutlinedButton(contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp), enabled = uri.scheme in listOf("https", "http") && !uri.host.isNullOrBlank(), onClick = {
                            try { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, uri)) } catch (_: android.content.ActivityNotFoundException) { }
                        }) { Icon(Icons.Outlined.Language, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text(t("打开", "Open")) }
                    }
                }
                DetailSection(t("登录信息", "Login information")) {
                    DetailField(t("用户名", "Username"), item.optString("username"), vault, t)
                    DetailField(t("密码", "Password"), item.optString("password"), vault, t, secret = true)
                    if (item.optString("url").isNotBlank()) DetailField(t("网站", "Website"), item.optString("url"), vault, t)
                    if (item.optString("secret").isNotBlank()) DetailCodeRow(code, remaining, period, copy, t, compact = true)
                    if (item.optInt("passwordDuration") > 0) DetailValue(t("密码有效期", "Password validity"), t("${item.optInt("passwordDuration")} 天", "${item.optInt("passwordDuration")} days"))
                }
                val accounts = item.optJSONArray("accounts")?.objects().orEmpty()
                DetailSection(t("附加账号 · ${accounts.size}", "Additional accounts · ${accounts.size}")) {
                    if (accounts.isEmpty()) Text(t("同一网站的其他登录身份，例如测试账号或机器人账号。", "Other logins for the same site, such as test or bot accounts."), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    accounts.forEachIndexed { index, account -> key(account.optString("id"), index) {
                        DetailField(account.optString("label").ifBlank { t("账号 ${index + 2}", "Account ${index + 2}") }, account.optString("username"), vault, t)
                        DetailField(t("密码", "Password"), account.optString("password"), vault, t, secret = true)
                        PasswordHistory(account, vault, t)
                    } }
                }
            }
            "totp" -> {
                DetailGroup { DetailCodeRow(code, remaining, period, copy, t, nextCode = nextCode) }
                Text(t("最后 5 秒变为橙色。如持续失败，请在系统设置中开启自动确定时间。", "The last 5 seconds turn orange. If codes keep failing, enable automatic time in system settings."), Modifier.padding(horizontal = 5.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                DetailSection(t("配置信息", "Configuration")) {
                    DetailField(t("发行方", "Issuer"), item.optString("title"), vault, t)
                    DetailField(t("账号", "Account"), item.optString("username"), vault, t)
                    DetailField(t("设置密钥", "Setup key"), item.optString("secret"), vault, t, secret = true, monospace = true)
                    DetailValue(t("更新间隔", "Refresh interval"), t("$period 秒", "$period seconds"))
                }
            }
            "crypto" -> {
                if (!deleted) Button(onClick = { copy(item.optString("address")) }, enabled = item.optString("address").isNotBlank()) {
                    Icon(Icons.Outlined.ContentCopy, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)); Text(t("复制地址", "Copy address"))
                }
                DetailSection(t("钱包信息", "Wallet information")) {
                    DetailField(t("网络", "Network"), item.optString("network"), vault, t)
                    DetailField(t("收款地址", "Receiving address"), item.optString("address"), vault, t, monospace = true)
                    if (item.optString("derivationPath").isNotBlank()) DetailField(t("派生路径", "Derivation path"), item.optString("derivationPath"), vault, t, monospace = true)
                    if (item.optString("privateKey").isNotBlank()) DetailField(t("私钥", "Private key"), item.optString("privateKey"), vault, t, secret = true, monospace = true)
                }
                if (item.optString("mnemonic").isNotBlank()) {
                    DetailSection(t("助记词 · ${item.optString("mnemonic").trim().split(Regex("\\s+")).size} 个", "Recovery phrase · ${item.optString("mnemonic").trim().split(Regex("\\s+")).size} words")) {
                        DetailField(t("助记词", "Recovery phrase"), item.optString("mnemonic"), vault, t, secret = true, words = true)
                    }
                    Text(t("助记词只在此页面显示，不提供复制。请避免旁观或屏幕共享。", "The recovery phrase is shown only on this page and cannot be copied. Avoid onlookers and screen sharing."), Modifier.padding(horizontal = 5.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            "creditCard", "identity" -> {
                val card = type == "creditCard"
                val group = item.optJSONObject(if (card) "card" else "identity") ?: JSONObject()
                if (card) {
                    PaymentCardPreview(group, t)
                    if (!deleted) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = { copy(group.optString("number")) }, enabled = group.optString("number").isNotBlank()) { Text(t("复制卡号", "Copy card number")) }
                        OutlinedButton(onClick = { copy(group.optString("securityCode")) }, enabled = group.optString("securityCode").isNotBlank()) { Text(t("复制安全码", "Copy security code")) }
                    }
                }
                DetailSection(if (card) t("银行卡信息", "Card information") else t("证件信息", "Identity information")) {
                    val preferred = if (card) listOf("cardholder", "number", "expiryDate", "securityCode", "pin") else listOf("fullName", "documentType", "documentNumber", "idNumber", "passportNumber", "issuingAuthority", "expiryDate")
                    val combined = if (card) setOf("bank", "brand", "expiryMonth", "expiryYear") else setOf("firstName", "lastName")
                    val fields = preferred.filter { group.has(it) || (it == "expiryDate" && card && (group.has("expiryMonth") || group.has("expiryYear"))) || (it == "fullName" && !card && (group.has("firstName") || group.has("lastName"))) }
                    (fields + group.keys().asSequence().toList().filter { it !in preferred && it !in combined }.sorted()).forEach { field ->
                        val value = when {
                            card && field == "expiryDate" -> group.optString(field).ifBlank { listOf(group.optString("expiryMonth"), group.optString("expiryYear").takeLast(2)).filter { it.isNotBlank() }.joinToString("/") }
                            !card && field == "fullName" -> group.optString(field).ifBlank { if (t("zh", "en") == "zh") group.optString("lastName") + group.optString("firstName") else listOf(group.optString("firstName"), group.optString("lastName")).filter { it.isNotBlank() }.joinToString(" ") }
                            else -> group.optString(field)
                        }
                        DetailField(if (field == "fullName") t("姓名", "Name") else if (card && field == "expiryDate") t("有效期", "Expiry") else structuredFieldLabel(field, t), value, vault, t, secret = field in listOf("number", "securityCode", "pin", "documentNumber", "idNumber", "passportNumber"), monospace = field in listOf("number", "securityCode", "pin"))
                    }
                }
            }
        }
        PasskeyRecordsPanel(item, vault, t)
        val custom = item.optJSONArray("customFields")?.objects().orEmpty()
        custom.groupBy { it.optString("group").ifBlank { t("自定义字段", "Custom fields") } }.forEach { (name, fields) ->
            DetailSection(name) { fields.forEach { DetailField(it.optString("label"), it.optString("value"), vault, t, secret = it.optString("kind") == "concealed") } }
        }
        if (listOf("category", "email", "sharedVaultId").any { item.optString(it).isNotBlank() } || entryTags(item).isNotEmpty() || (type != "password" && item.optString("url").isNotBlank())) DetailSection(t("分类与资料库", "Category and vault")) {
            if (item.optString("category").isNotBlank()) DetailValue(t("分类", "Category"), item.optString("category"))
            if (type != "password" && item.optString("url").isNotBlank()) DetailField(t("网站", "Website"), item.optString("url"), vault, t)
            if (item.optString("email").isNotBlank()) DetailField(t("邮箱", "Email"), item.optString("email"), vault, t)
            if (item.optString("sharedVaultId").isNotBlank()) DetailValue(t("所属资料库", "Vault"), state.sharedVaults.firstOrNull { it.optString("id") == item.optString("sharedVaultId") }?.optString("name").orEmpty().ifBlank { t("共享资料库", "Shared vault") })
            if (entryTags(item).isNotEmpty()) FlowRow(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                entryTags(item).forEach { tag -> Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(20.dp)) { Text("#$tag", Modifier.padding(horizontal = 8.dp, vertical = 3.dp), style = MaterialTheme.typography.labelSmall) } }
            }
        }
        if (type != "device") DetailSection(t("备注", "Notes")) {
            if (item.optString("note").isBlank()) Text(t("没有备注。", "No notes."), Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            else Box(Modifier.padding(16.dp)) { MarkdownNote(item.optString("note")) }
        }
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(t("历史", "History"), Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                TextButton(onClick = { history = true }) { Text(t("版本历史", "Version history")) }
            }
            DetailGroup {
                if (type == "password" || type == "totp") {
                    if ((item.optJSONArray("passwordHistory")?.length() ?: 0) == 0) DetailValue(t("密码历史", "Password history"), t("没有旧密码", "No previous passwords"))
                    else PasswordHistory(item, vault, t)
                }
                DetailValue(t("修改时间", "Modified"), noteDate(item))
            }
        }
    }
}

@Composable
internal fun DetailHero(item: JSONObject, t: (String, String) -> String) {
    val type = item.optString("type")
    Row(Modifier.padding(horizontal = 5.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        val initial = item.optString("title").take(1).uppercase()
        val brandColor = legacyItemColor(item.optString("colorLabel")) ?: when (initial) {
            "G" -> androidx.compose.ui.graphics.Color(0xFF24292F); "A" -> androidx.compose.ui.graphics.Color(0xFF555B66); "公" -> androidx.compose.ui.graphics.Color(0xFF3265DB); "F" -> androidx.compose.ui.graphics.Color(0xFFA259FF); "招" -> androidx.compose.ui.graphics.Color(0xFFC8102E); "家" -> androidx.compose.ui.graphics.Color(0xFF2F8F63); "旧" -> androidx.compose.ui.graphics.Color(0xFF8A8F98); "C" -> androidx.compose.ui.graphics.Color(0xFFF38020); else -> androidx.compose.ui.graphics.Color(0xFF6B7A93)
        }
        Surface(color = if (type == "password") brandColor else MaterialTheme.colorScheme.primaryContainer, shape = RoundedCornerShape(23.dp), modifier = Modifier.size(84.dp)) {
            Box(contentAlignment = Alignment.Center) {
                if (type == "password") Text(initial, style = MaterialTheme.typography.headlineLarge, color = androidx.compose.ui.graphics.Color.White)
                else Icon(when (type) { "totp" -> Icons.Outlined.Timer; "crypto" -> Icons.Outlined.AccountBalanceWallet; "creditCard" -> Icons.Outlined.CreditCard; "identity" -> Icons.Outlined.Badge; "device" -> Icons.Outlined.Dns; else -> Icons.Outlined.Key }, null, Modifier.size(36.dp), tint = MaterialTheme.colorScheme.primary)
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(item.optString("title"), style = MaterialTheme.typography.titleLarge)
            val subtitle = when (type) { "totp" -> item.optString("username"); "crypto" -> item.optString("network"); "device" -> item.optJSONObject("device")?.optString("host").orEmpty(); "creditCard" -> item.optJSONObject("card")?.optString("brand").orEmpty(); "identity" -> t("身份证件", "Identity"); else -> listOf(item.optString("url"), item.optString("category")).filter { it.isNotBlank() }.joinToString(" · ") }
            if (subtitle.isNotBlank()) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun DetailGroup(content: @Composable ColumnScope.() -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(16.dp)) {
        Column(Modifier.fillMaxWidth(), content = content)
    }
}

@Composable
internal fun DetailSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title, Modifier.padding(start = 5.dp, top = 2.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        DetailGroup(content)
    }
}

@Composable
private fun DetailCodeRow(code: String, remaining: Int, period: Int, copy: (String) -> Unit, t: (String, String) -> String, compact: Boolean = false, nextCode: String = "") {
    val tint = if (remaining <= 5 && code.isNotBlank()) androidx.compose.ui.graphics.Color(0xFFB86A12) else MaterialTheme.colorScheme.primary
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!compact) Box(contentAlignment = Alignment.Center) {
            CircularProgressIndicator(progress = { if (code.isBlank()) 0f else remaining.toFloat() / period }, modifier = Modifier.size(38.dp), color = tint, trackColor = MaterialTheme.colorScheme.outlineVariant, strokeWidth = 3.dp)
            Text(remaining.toString(), style = MaterialTheme.typography.labelSmall, color = tint)
        }
        Column(Modifier.weight(1f)) {
            if (compact) Text(t("一次性验证码 · $remaining 秒", "One-time code · ${remaining}s"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(code.ifBlank { "—— ——" }.chunked(3).joinToString(" "), style = if (compact) MaterialTheme.typography.titleLarge else MaterialTheme.typography.headlineMedium, fontFamily = FontFamily.Monospace, color = tint)
            if (!compact && nextCode.isNotBlank()) Text(t("下一个 ", "Next ") + nextCode.chunked(3).joinToString(" "), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (!compact) Text(if (code.isBlank()) t("无法生成，请检查设置密钥", "Could not generate; check the setup key") else t("剩 $remaining 秒", "${remaining}s remaining"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onClick = { copy(code) }, enabled = code.isNotBlank()) { Icon(Icons.Outlined.ContentCopy, t("复制验证码", "Copy code"), tint = tint) }
    }
}

@Composable
private fun PaymentCardPreview(card: JSONObject, t: (String, String) -> String) {
    Surface(modifier = Modifier.padding(horizontal = 3.dp), shape = RoundedCornerShape(17.dp), color = androidx.compose.ui.graphics.Color(0xFF78142D), contentColor = androidx.compose.ui.graphics.Color.White) {
        Column(Modifier.fillMaxWidth().background(androidx.compose.ui.graphics.Brush.linearGradient(listOf(androidx.compose.ui.graphics.Color(0xFFB3122D), androidx.compose.ui.graphics.Color(0xFF5D0C22)))).aspectRatio(1.6f).padding(18.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Row(Modifier.fillMaxWidth()) { Text(card.optString("bank").ifBlank { t("银行卡", "Payment card") }, Modifier.weight(1f)); Text(card.optString("brand")) }
            Text("•••• •••• •••• " + card.optString("number").filter { it.isDigit() }.takeLast(4), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.titleLarge)
            Row(Modifier.fillMaxWidth()) { Text(card.optString("cardholder"), Modifier.weight(1f)); Text(card.optString("expiryDate").ifBlank { listOf(card.optString("expiryMonth"), card.optString("expiryYear")).filter { it.isNotBlank() }.joinToString("/") }) }
        }
    }
}

@Composable
internal fun DetailValue(label: String, value: String) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
internal fun DetailField(
    label: String,
    value: String,
    vault: VaultRepository,
    t: (String, String) -> String,
    secret: Boolean = false,
    monospace: Boolean = false,
    words: Boolean = false,
) {
    var visible by remember(label, value) { mutableStateOf(false) }
    var revealConfirmation by remember(label, value) { mutableStateOf(false) }
    val copy = LocalDetailCopy.current ?: vault::copy
    if (words && revealConfirmation) AlertDialog(
        onDismissRequest = { revealConfirmation = false },
        title = { Text(t("显示助记词？", "Reveal recovery phrase?")) },
        text = { Text(t("任何看到助记词的人都能控制钱包。请确认周围没有他人或屏幕共享。", "Anyone who sees this phrase can control the wallet. Check for people nearby or screen sharing.")) },
        confirmButton = { TextButton(onClick = { revealConfirmation = false; visible = true }) { Text(t("显示", "Reveal")) } },
        dismissButton = { TextButton(onClick = { revealConfirmation = false }) { Text(t("取消", "Cancel")) } },
    )
    Column {
        Row(Modifier.fillMaxWidth().heightIn(min = 58.dp).padding(start = 16.dp, end = 4.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (!words) Text(when { value.isEmpty() -> t("未填写", "Not set"); secret && !visible -> "••••••••••••"; else -> value }, style = MaterialTheme.typography.bodyMedium, color = if (label == t("网站", "Website")) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface, fontFamily = if (monospace || secret) FontFamily.Monospace else FontFamily.Default)
            }
            if (secret) IconButton(onClick = { if (words && !visible) revealConfirmation = true else visible = !visible }, enabled = value.isNotEmpty()) {
                Icon(if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility, if (visible) t("隐藏$label", "Hide $label") else t("显示$label", "Show $label"), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (!words) IconButton(onClick = { copy(value) }, enabled = value.isNotEmpty()) { Icon(Icons.Outlined.ContentCopy, t("复制$label", "Copy $label"), Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        if (words) {
            val entries = value.trim().split(Regex("\\s+"))
            val columns = if (androidx.compose.ui.platform.LocalDensity.current.fontScale > 1.2f) 2 else 3
            Column(Modifier.padding(start = 12.dp, end = 12.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                entries.chunked(columns).forEachIndexed { row, group ->
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        group.forEachIndexed { col, word ->
                            Surface(Modifier.weight(1f), color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(8.dp)) {
                                Text("${row * columns + col + 1}  " + if (visible) word else "•••••", Modifier.padding(horizontal = 8.dp, vertical = 8.dp), fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        repeat(columns - group.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
        HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f), thickness = 0.5.dp)
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
    var expanded by remember(account.toString()) { mutableStateOf(false) }
    val historyLabel = if (expanded) t("收起密码历史", "Hide password history")
        else t("密码历史（${history.size}）", "Password history (${history.size})")
    TextButton(onClick = { expanded = !expanded }) {
        Icon(Icons.Outlined.History, null, Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(historyLabel)
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

internal fun structuredFieldLabel(key: String, t: (String, String) -> String): String = when (key) {
    "bank" -> t("发卡行", "Issuing bank")
    "cardholder" -> t("持卡人", "Cardholder")
    "number" -> t("卡号", "Card number")
    "expiryMonth" -> t("到期月", "Expiry month")
    "expiryYear" -> t("到期年", "Expiry year")
    "expiryDate" -> t("到期日期", "Expiry date")
    "expirationDate" -> t("到期日期", "Expiry date")
    "securityCode" -> t("安全码", "Security code")
    "brand" -> t("卡组织", "Card network")
    "pin" -> t("取款密码", "PIN")
    "firstName" -> t("名", "First name")
    "lastName" -> t("姓", "Last name")
    "fullName" -> t("姓名", "Full name")
    "email" -> t("邮箱", "Email")
    "phone" -> t("电话", "Phone")
    "address1" -> t("地址", "Address")
    "address2" -> t("地址补充", "Address line 2")
    "fullAddress" -> t("完整地址", "Full address")
    "city" -> t("城市", "City")
    "region" -> t("省 / 州", "State / province")
    "postalCode" -> t("邮编", "Postal code")
    "country" -> t("国家", "Country")
    "company" -> t("公司", "Company")
    "documentNumber" -> t("证件号码", "Document number")
    "documentType" -> t("证件类型", "Document type")
    "passportNumber" -> t("护照号码", "Passport number")
    "idNumber" -> t("身份号码", "Identity number")
    "birthDate", "dateOfBirth" -> t("出生日期", "Date of birth")
    "issueDate" -> t("签发日期", "Issue date")
    "issuingAuthority" -> t("签发机关", "Issuing authority")
    "nationality" -> t("国籍", "Nationality")
    else -> t("其他字段", "Other field") + " · " + key
}
