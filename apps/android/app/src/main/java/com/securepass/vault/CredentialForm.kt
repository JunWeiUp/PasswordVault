package com.securepass.vault

// The entry editor form for every credential type (ported from the former Flutter client;
// the `legacy*` option lists keep their stored values for compatibility).

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

internal val legacyCategories = listOf("社交媒体", "财务", "工作", "购物", "娱乐", "加密资产", "笔记")
internal val legacyNetworks =
    listOf("ETH", "BTC", "BSC", "Polygon", "Solana", "TRON", "AVAX", "Arbitrum", "Optimism")
internal val legacyColors =
    linkedMapOf(
        "红色" to Color(0xFFE45757),
        "橙色" to Color(0xFFFF9800),
        "黄色" to Color(0xFFFFC107),
        "绿色" to Color(0xFF4CAF50),
        "蓝色" to Color(0xFF2196F3),
        "紫色" to Color(0xFF9C27B0),
        "粉色" to Color(0xFFE91E63),
        "青色" to Color(0xFF009688),
    )

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun CredentialForm(
    draft: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    set: (String, Any) -> Unit,
    generatePassword: (String?) -> Unit,
    deriveWallet: (String) -> Unit,
    generateWallet: () -> Unit,
    report: (String) -> Unit,
    busyChanged: (Boolean) -> Unit,
) {
    val kind = draft.optString("type")
    val enabled = LocalEditorEnabled.current
    val scope = rememberCoroutineScope()
    var twoFactor by remember { mutableStateOf(false) }
    var secretInput by remember { mutableStateOf("") }
    var link by remember { mutableStateOf("") }
    var tagInput by remember { mutableStateOf("") }
    var removeAccount by remember { mutableStateOf<String?>(null) }
    val accounts = draft.optJSONArray("accounts")?.objects().orEmpty()
    fun accountSet(id: String, field: String, value: String) {
        val next = JSONArray(draft.optJSONArray("accounts")?.toString() ?: "[]")
        next.objects().firstOrNull { it.optString("id") == id }?.put(field, value)
        set("accounts", next)
    }
    fun importLink(value: String) {
        busyChanged(true)
        scope.launch {
            try {
                val parsed = vault.command(CoreRequest.parseTotp(value))
                listOf("title", "username", "secret", "period").forEach {
                    if (parsed.has(it)) set(it, parsed.get(it))
                }
                link = ""
            } catch (_: Exception) {
                report(t("设置链接无效，输入已保留。", "Invalid setup link; your input is preserved."))
            } finally {
                busyChanged(false)
            }
        }
    }
    EditorFormSection {
        EditorField(
            t("标题 *", "Title *"),
            draft.optString("title"),
            { set("title", it) },
            vault,
            t,
            copy = false,
        )
        if (kind in listOf("password", "totp")) EditorHeading(t("登录信息", "Login information"))
        if (kind in listOf("password", "totp"))
            EditorField(
                t("用户名", "Username"),
                draft.optString("username"),
                { set("username", it) },
                vault,
                t,
            )
        if (kind in listOf("password", "totp")) {
            EditorField(
                t("密码", "Password"),
                draft.optString("password"),
                { set("password", it) },
                vault,
                t,
                secret = true,
                generate = { generatePassword(null) },
            )
            if (kind == "password") PasswordStrengthBar(draft.optString("password"), t, Modifier.fillMaxWidth().padding(horizontal = 4.dp))
            draft
                .optString("passwordLastChanged")
                .takeIf { it.isNotBlank() }
                ?.let {
                    Text(
                        t("上次修改 · ", "Last changed · ") + it,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            PasswordHistory(draft, vault, t)
        }
        if (kind == "crypto") {
            EditorField(
                t("钱包地址", "Wallet address"),
                draft.optString("address"),
                { set("address", it) },
                vault,
                t,
                lines = 2,
            )
            TextButton(enabled = enabled, onClick = { deriveWallet("privateKey") }) {
                Text(t("根据私钥更新 ETH 地址", "Update ETH address from private key"))
            }
            ChoiceEditor(
                t("区块链网络", "Network"),
                draft.optString("network"),
                (legacyNetworks + vault.state.value.entries.map { it.optString("network") })
                    .filter { it.isNotBlank() }
                    .distinct(),
                t,
            ) {
                set("network", it)
            }
        }
        if (kind == "password") {
            EditorField(t("网站", "Website"), draft.optString("url"), { set("url", it) }, vault, t, copy = false)
            Text(t("浏览器与 Android 自动填充按精确主机名匹配", "Browser and Android autofill match the exact hostname"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

    }
    if (kind in listOf("creditCard", "identity")) AlignedStructuredGroup(draft, vault, set, t)
    if (kind == "password") DetailGroup {
        Surface(onClick = { secretInput = draft.optString("secret"); twoFactor = true }, enabled = enabled, color = MaterialTheme.colorScheme.surface) {
            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(Icons.Outlined.QrCode, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Column(Modifier.weight(1f)) {
                    Text(t("一次性验证码", "One-time code"), style = MaterialTheme.typography.bodyMedium)
                    Text(if (draft.optString("secret").isBlank()) t("扫描二维码或输入密钥", "Scan a QR code or enter a setup key") else t("已配置", "Configured"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Icon(Icons.Outlined.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }

    if (kind in listOf("password", "totp")) {
        EditorFormSection {
            EditorHeading(t("附加账号", "Additional accounts"))
            if (accounts.isEmpty())
                Text(
                    t("同一网站的其他账号可以保存在这里。", "Keep other logins for the same site here."),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            accounts.forEachIndexed { index, account ->
                val id = account.optString("id")
                key(id) {
                    if (index > 0) HorizontalDivider()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            t("账号 ${index + 2}", "Account ${index + 2}"),
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.primary,
                        )
                        IconButton(enabled = enabled, onClick = { removeAccount = id }) {
                            Icon(
                                Icons.Outlined.RemoveCircleOutline,
                                t("移除账号 ${index + 2}", "Remove account ${index + 2}"),
                            )
                        }
                    }
                    EditorField(
                        t("用途 ${index + 2}", "Purpose ${index + 2}"),
                        account.optString("label"),
                        { accountSet(id, "label", it) },
                        vault,
                        t,
                        copy = false,
                    )
                    EditorField(
                        t("用户名 ${index + 2}", "Username ${index + 2}"),
                        account.optString("username"),
                        { accountSet(id, "username", it) },
                        vault,
                        t,
                    )
                    EditorField(
                        t("密码 ${index + 2}", "Password ${index + 2}"),
                        account.optString("password"),
                        { accountSet(id, "password", it) },
                        vault,
                        t,
                        secret = true,
                        generate = { generatePassword(id) },
                    )
                    account
                        .optString("passwordLastChanged")
                        .takeIf { it.isNotBlank() }
                        ?.let {
                            Text(
                                t("上次修改 · ", "Last changed · ") + it,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    PasswordHistory(account, vault, t)
                }
            }
            EditorActionButton(
                enabled = enabled,
                onClick = {
                    set(
                        "accounts",
                        JSONArray(accounts.map { JSONObject(it.toString()) })
                            .put(
                                JSONObject()
                                    .put("id", java.util.UUID.randomUUID().toString())
                                    .put("username", "")
                                    .put("password", "")
                                    .put("label", "")
                            ),
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.Add, null)
                Text(t("添加另一个账号", "Add another account"))
            }
        }

    }
    if (kind == "totp")
        EditorFormSection {
            EditorHeading(t("验证码设置", "Code settings"))
            EditorField(
                t("设置密钥", "Setup key"),
                draft.optString("secret"),
                { set("secret", it.replace(" ", "").uppercase()) },
                vault,
                t,
                secret = true,
            )
            EditorField(
                t("刷新间隔（秒）", "Period (seconds)"),
                draft.optInt("period", 30).toString(),
                { set("period", it.toIntOrNull() ?: 0) },
                vault,
                t,
                copy = false,
                numeric = true,
            )
            QrImport(
                vault,
                t,
                result = ::importLink,
                error = {
                    report(t("未识别到二维码，可手动粘贴设置链接。", "No QR found; paste a setup link instead."))
                },
            )
            EditorField(
                t("设置链接", "Setup link"),
                link,
                { link = it },
                vault,
                t,
                secret = true,
                copy = false,
            )
            TextButton(enabled = enabled && link.isNotBlank(), onClick = { importLink(link) }) {
                Text(t("导入设置链接", "Import setup link"))
            }
            TextButton(
                enabled = enabled && draft.optString("secret").isNotBlank(),
                onClick = { vault.copy(totpSetupUri(draft)) },
            ) {
                Text(t("复制 otpauth 链接", "Copy otpauth link"))
            }
        }
    if (kind == "crypto") {
        EditorFormSection {
            EditorHeading(t("私钥详情", "Private key details"))
            EditorField(
                t("私钥", "Private key"),
                draft.optString("privateKey"),
                { set("privateKey", it) },
                vault,
                t,
                secret = true,
                lines = 2,
            )
        }
        EditorFormSection {
            EditorHeading(t("助记词", "Recovery phrase"))
            RecoveryWordsEditor(draft.optString("mnemonic"), { set("mnemonic", it) }, vault, t)
            TextButton(enabled = enabled, onClick = { deriveWallet("mnemonic") }) {
                Text(t("根据助记词更新私钥和地址", "Update key and address from recovery phrase"))
            }
            EditorActionButton(
                enabled = enabled,
                onClick = generateWallet,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(t("生成 ETH 钱包助记词", "Generate ETH recovery phrase"))
            }
        }
    }
    EditorFormSection {
        EditorHeading(t("分类与备注", "Category and notes"))
        ChoiceEditor(t("分类", "Category"), draft.optString("category"), (listOf("个人", "工作", "家庭", "金融") + legacyCategories + vault.state.value.entries.map { it.optString("category") }).filter { it.isNotBlank() }.distinct(), t) { set("category", it) }
        if (kind != "crypto") {
            EditorField(t("邮箱", "Email"), draft.optString("email"), { set("email", it) }, vault, t)
            if (kind != "password") EditorField(
                t("网站 / 域名", "Websites / domains"),
                draft.optString("url"),
                { set("url", it) },
                vault,
                t,
                lines = 2,
            )
        }
        Text(t("标签", "Tags"), style = MaterialTheme.typography.labelLarge)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            entryTags(draft).forEach { tag ->
                InputChip(
                    selected = false,
                    onClick = { set("tags", JSONArray(entryTags(draft).filter { it != tag })) },
                    enabled = enabled,
                    label = { Text(tag) },
                    trailingIcon = {
                        Icon(
                            Icons.Outlined.Close,
                            t("移除标签 $tag", "Remove tag $tag"),
                            Modifier.size(16.dp),
                        )
                    },
                )
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                tagInput,
                { tagInput = it },
                Modifier.weight(1f),
                enabled = enabled,
                singleLine = true,
                label = { Text(t("新标签", "New tag")) },
            )
            TextButton(
                enabled = enabled && tagInput.isNotBlank(),
                onClick = {
                    set("tags", JSONArray((entryTags(draft) + tagInput.trim()).distinct()))
                    tagInput = ""
                },
            ) {
                Text(t("添加", "Add"))
            }
        }
        EditorField(
            t("备注", "Notes"),
            draft.optString("note"),
            { set("note", it) },
            vault,
            t,
            lines = 3,
        )

    }
    EditorVaultDestination(draft, vault, set, t)
    if (kind in listOf("password", "totp"))
        EditorFormSection {
            EditorHeading(t("密码安全", "Password security"))
            EditorField(
                t("密码有效期（天）", "Password expiry (days)"),
                if (draft.isNull("passwordDuration")) "" else draft.optString("passwordDuration"),
                { value ->
                    if (value.isBlank()) set("passwordDuration", JSONObject.NULL)
                    else
                        value.toIntOrNull()?.takeIf { it >= 0 }?.let { set("passwordDuration", it) }
                },
                vault,
                t,
                copy = false,
                numeric = true,
            )
            Text(
                t("留空表示不限制有效期。", "Leave blank for no expiry."),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    EditorFormSection {
        EditorHeading(t("显示设置", "Display settings"))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(t("置顶", "Pin to top"), Modifier.weight(1f))
            Switch(draft.optBoolean("isPinned"), { set("isPinned", it) }, enabled = enabled)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(t("收藏", "Favorite"), Modifier.weight(1f))
            Switch(draft.optBoolean("isFavorite"), { set("isFavorite", it) }, enabled = enabled)
        }
        ChoiceEditor(
            t("颜色标记", "Color label"),
            draft.optString("colorLabel"),
            legacyColors.keys.toList(),
            t,
            allowCustom = false,
        ) {
            set("colorLabel", it)
        }
    }
    if (removeAccount != null)
        AlertDialog(
            onDismissRequest = { removeAccount = null },
            title = { Text(t("移除此附加账号？", "Remove this additional account?")) },
            text = { Text(t("保存前仍可放弃本次修改。", "You can discard this edit before saving.")) },
            confirmButton = {
                TextButton(
                    onClick = {
                        set(
                            "accounts",
                            JSONArray(accounts.filter { it.optString("id") != removeAccount }),
                        )
                        removeAccount = null
                    }
                ) {
                    Text(t("移除", "Remove"))
                }
            },
            dismissButton = {
                TextButton(onClick = { removeAccount = null }) { Text(t("取消", "Cancel")) }
            },
        )
    if (twoFactor) ModalBottomSheet(onDismissRequest = { twoFactor = false }, containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).navigationBarsPadding().imePadding().verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(t("添加验证码", "Add verification code"), style = MaterialTheme.typography.titleLarge)
            Text(t("扫描二维码或手动输入设置密钥。", "Scan a QR code or enter the setup key."), color = MaterialTheme.colorScheme.onSurfaceVariant)
            QrImport(vault, t, result = { uri ->
                busyChanged(true)
                scope.launch {
                    try {
                        val parsed = vault.command(CoreRequest.parseTotp(uri))
                        secretInput = parsed.getString("secret")
                        if (parsed.has("period")) set("period", parsed.get("period"))
                    } catch (_: Exception) { report(t("设置链接无效，输入已保留。", "Invalid setup link; your input is preserved.")) }
                    finally { busyChanged(false) }
                }
            }, error = { report(t("未识别到二维码，可手动输入密钥。", "No QR found; enter the setup key instead.")) })
            EditorField(t("设置密钥", "Setup key"), secretInput, { secretInput = it }, vault, t, secret = true, copy = false)
            Button(enabled = enabled && secretInput.isNotBlank(), onClick = {
                set("secret", secretInput.filterNot { it.isWhitespace() }.uppercase()); twoFactor = false
            }, modifier = Modifier.fillMaxWidth()) { Text(t("确认", "Confirm")) }
            TextButton(enabled = enabled, onClick = { set("secret", ""); twoFactor = false }, modifier = Modifier.fillMaxWidth()) { Text(t("清除配置", "Clear configuration")) }
            Spacer(Modifier.height(16.dp))
        }
    }

}

@Composable
internal fun EditorHeading(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        color =
            if (LocalAccountForm.current) MaterialTheme.colorScheme.onSurface
            else MaterialTheme.colorScheme.primary,
    )
}

@Composable
internal fun EditorField(
    label: String,
    value: String,
    change: (String) -> Unit,
    vault: VaultRepository,
    t: (String, String) -> String,
    secret: Boolean = false,
    copy: Boolean = false,
    lines: Int = 1,
    generate: (() -> Unit)? = null,
    numeric: Boolean = false,
) {
    var visible by remember { mutableStateOf(false) }
    val enabled = LocalEditorEnabled.current
    if (LocalAccountForm.current) {
        val separateActions =
            LocalConfiguration.current.screenWidthDp < 380 || LocalDensity.current.fontScale > 1.25f
        val fieldActions: @Composable () -> Unit = {
            Row {
                if (secret)
                    IconButton(enabled = enabled, onClick = { visible = !visible }) {
                        Icon(
                            if (visible) Icons.Outlined.VisibilityOff
                            else Icons.Outlined.Visibility,
                            if (visible) t("隐藏$label", "Hide $label")
                            else t("显示$label", "Show $label"),
                            Modifier.size(20.dp),
                        )
                    }
                if (copy)
                    IconButton(enabled = value.isNotEmpty(), onClick = { vault.copy(value) }) {
                        Icon(
                            Icons.Outlined.ContentCopy,
                            t("复制$label", "Copy $label"),
                            Modifier.size(20.dp),
                        )
                    }
                if (generate != null)
                    IconButton(enabled = enabled, onClick = generate) {
                        Icon(
                            Icons.Outlined.Casino,
                            t("生成$label", "Generate $label"),
                            Modifier.size(20.dp),
                        )
                    }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(label, Modifier.padding(start = 5.dp), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(
                value,
                change,
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = label },
                enabled = enabled,
                singleLine = lines == 1,
                minLines = lines,
                textStyle = MaterialTheme.typography.bodyLarge,
                visualTransformation =
                    if (secret && !visible) PasswordVisualTransformation()
                    else VisualTransformation.None,
                keyboardOptions =
                    androidx.compose.foundation.text.KeyboardOptions(
                        autoCorrectEnabled = false,
                        keyboardType =
                            if (numeric) androidx.compose.ui.text.input.KeyboardType.Number
                            else if (secret) androidx.compose.ui.text.input.KeyboardType.Password
                            else androidx.compose.ui.text.input.KeyboardType.Text,
                    ),
                trailingIcon =
                    if (!separateActions && (secret || copy || generate != null)) fieldActions
                    else null,
                shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
                colors =
                    OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = accountFieldColor(),
                        unfocusedContainerColor = accountFieldColor(),
                        disabledContainerColor = accountFieldColor(),
                        unfocusedBorderColor = Color.Transparent,
                        disabledBorderColor = Color.Transparent,
                    ),
            )
            if (separateActions && (secret || copy || generate != null))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    fieldActions()
                }
        }
        return
    }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label,
                Modifier.weight(1f),
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (secret)
                IconButton(enabled = enabled, onClick = { visible = !visible }) {
                    Icon(
                        if (visible) Icons.Outlined.VisibilityOff else Icons.Outlined.Visibility,
                        if (visible) t("隐藏$label", "Hide $label") else t("显示$label", "Show $label"),
                    )
                }
            if (copy)
                IconButton(enabled = value.isNotEmpty(), onClick = { vault.copy(value) }) {
                    Icon(Icons.Outlined.ContentCopy, t("复制$label", "Copy $label"))
                }
            if (generate != null)
                IconButton(enabled = enabled, onClick = generate) {
                    Icon(Icons.Outlined.Casino, t("生成$label", "Generate $label"))
                }
        }
        OutlinedTextField(
            value,
            change,
            modifier = Modifier.fillMaxWidth().semantics { contentDescription = label },
            enabled = enabled,
            singleLine = lines == 1,
            minLines = lines,
            visualTransformation =
                if (secret && !visible) PasswordVisualTransformation()
                else VisualTransformation.None,
            keyboardOptions =
                androidx.compose.foundation.text.KeyboardOptions(
                    autoCorrectEnabled = false,
                    keyboardType =
                        if (numeric) androidx.compose.ui.text.input.KeyboardType.Number
                        else if (secret) androidx.compose.ui.text.input.KeyboardType.Password
                        else androidx.compose.ui.text.input.KeyboardType.Text,
                ),
            placeholder = { Text(label) },
            shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp),
        )
    }
}

@Composable
internal fun ChoiceEditor(
    label: String,
    value: String,
    options: List<String>,
    t: (String, String) -> String,
    allowCustom: Boolean = true,
    selected: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var custom by remember { mutableStateOf("") }
    if (LocalAccountForm.current) {
        Surface(
            onClick = {
                custom = ""
                open = true
            },
            enabled = LocalEditorEnabled.current,
            color = accountFieldColor(),
            shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Row(
                Modifier.heightIn(min = 48.dp).padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(value.ifEmpty { t("无", "None") }, style = MaterialTheme.typography.bodyMedium)
                }
                Icon(
                    Icons.Outlined.ExpandMore,
                    null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    } else
        EditorActionButton(
            enabled = LocalEditorEnabled.current,
            onClick = {
                custom = ""
                open = true
            },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("$label · " + value.ifEmpty { t("无", "None") }, Modifier.weight(1f))
            Icon(Icons.Outlined.ExpandMore, null)
        }
    if (open)
        AlertDialog(
            onDismissRequest = { open = false },
            title = { Text(label) },
            text = {
                Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                    (listOf("") + options).distinct().forEach { option ->
                        TextButton(
                            onClick = {
                                selected(option)
                                open = false
                            },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(option.ifEmpty { t("无", "None") }, Modifier.weight(1f))
                            if (option == value) Icon(Icons.Outlined.Check, null)
                        }
                    }
                    if (allowCustom)
                        OutlinedTextField(
                            custom,
                            { custom = it },
                            label = { Text(t("新增$label", "New $label")) },
                            singleLine = true,
                        )
                }
            },
            confirmButton = {
                if (allowCustom)
                    TextButton(
                        enabled = custom.isNotBlank(),
                        onClick = {
                            selected(custom.trim())
                            open = false
                        },
                    ) {
                        Text(t("添加", "Add"))
                    }
            },
            dismissButton = { TextButton(onClick = { open = false }) { Text(t("取消", "Cancel")) } },
        )
}

internal fun totpSetupUri(item: JSONObject): String {
    fun encode(value: String) = java.net.URLEncoder.encode(value, "UTF-8").replace("+", "%20")
    return "otpauth://totp/${encode(item.optString("title"))}:${encode(item.optString("username"))}?secret=${encode(item.optString("secret"))}&issuer=${encode(item.optString("title"))}&period=${item.optInt("period", 30)}"
}

@Composable
private fun RecoveryWordsEditor(
    value: String,
    change: (String) -> Unit,
    vault: VaultRepository,
    t: (String, String) -> String,
) {
    var revealed by remember { mutableStateOf(false) }
    var paste by remember { mutableStateOf(false) }
    var confirmReveal by remember { mutableStateOf(false) }
    if (confirmReveal) AlertDialog(
        onDismissRequest = { confirmReveal = false },
        title = { Text(t("显示助记词？", "Reveal recovery phrase?")) },
        text = { Text(t("任何看到助记词的人都能控制钱包。请确认周围没有他人或屏幕共享。", "Anyone who sees this phrase can control the wallet. Check for people nearby or screen sharing.")) },
        confirmButton = { TextButton(onClick = { confirmReveal = false; revealed = true }) { Text(t("显示", "Reveal")) } },
        dismissButton = { TextButton(onClick = { confirmReveal = false }) { Text(t("取消", "Cancel")) } },
    )
    val words = value.split(' ')
    val count = maxOf(12, words.size)
    val columns = if (LocalDensity.current.fontScale > 1.2f) 2 else 3
    val context = LocalContext.current
    val dictionary = remember {
        context.assets.open("bip39-english.txt").bufferedReader().use { it.readLines() }
    }
    var focused by remember { mutableIntStateOf(-1) }
    val enabled = LocalEditorEnabled.current
    Row {
        TextButton(onClick = { if (revealed) revealed = false else confirmReveal = true }) {
            Text(
                if (revealed) t("隐藏助记词", "Hide recovery phrase")
                else t("显示助记词", "Show recovery phrase")
            )
        }
        TextButton(enabled = enabled, onClick = { paste = !paste }) {
            Text(t("粘贴整段", "Paste phrase"))
        }
    }
    if (paste)
        EditorField(
            t("完整助记词", "Full recovery phrase"),
            value,
            { change(it.trim().split(Regex("\\s+")).joinToString(" ")) },
            vault,
            t,
            secret = true,
            copy = false,
            lines = 2,
        )
    (0 until count).chunked(columns).forEach { indices ->
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            indices.forEach { index ->
                Column(Modifier.weight(1f)) {
                    OutlinedTextField(
                        words.getOrElse(index) { "" },
                        { word ->
                            val next = MutableList(count) { words.getOrElse(it) { "" } }
                            next[index] = word.trim().lowercase()
                            change(next.joinToString(" "))
                            focused = index
                        },
                        enabled = enabled,
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("${index + 1}") },
                        singleLine = true,
                        visualTransformation =
                            if (revealed) VisualTransformation.None
                            else PasswordVisualTransformation(),
                        keyboardOptions =
                            androidx.compose.foundation.text.KeyboardOptions(
                                autoCorrectEnabled = false,
                                keyboardType = androidx.compose.ui.text.input.KeyboardType.Password,
                            ),
                    )
                }
            }
            repeat(columns - indices.size) { Spacer(Modifier.weight(1f)) }
        }
        if (revealed && focused in indices) {
            val prefix = words.getOrElse(focused) { "" }
            val matches =
                if (prefix.isBlank()) emptyList()
                else dictionary.filter { it.startsWith(prefix) && it != prefix }.take(3)
            Row {
                matches.forEach { word ->
                    TextButton(
                        enabled = enabled,
                        onClick = {
                            val next = MutableList(count) { words.getOrElse(it) { "" } }
                            next[focused] = word
                            change(next.joinToString(" "))
                            focused = -1
                        },
                    ) {
                        Text(word)
                    }
                }
            }
        }
    }
}

internal fun legacyItemColor(label: String): Color? {
    val aliases = listOf("Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Cyan")
    return legacyColors[label]
        ?: aliases
            .indexOfFirst { it.equals(label, true) }
            .takeIf { it >= 0 }
            ?.let { legacyColors.values.toList()[it] }
}


/** Keeps imported/legacy keys editable while arranging the standard card and identity fields first. */
@Composable
internal fun AlignedStructuredFieldsEditor(
    draft: JSONObject,
    vault: VaultRepository,
    set: (String, Any) -> Unit,
    t: (String, String) -> String,
) {
    val fields = draft.optJSONArray("customFields") ?: JSONArray()
    val identity = draft.optString("type") == "identity"
    EditorFormSection {
        EditorHeading(t("自定义字段", "Custom fields"))
        for (index in 0 until fields.length()) {
            val field = fields.getJSONObject(index)
            fun change(name: String, value: String) {
                val next = JSONArray(fields.toString()); next.getJSONObject(index).put(name, value); set("customFields", next)
            }
            if (!(identity && IdentityDocument.isDocumentField(field))) key(field.optString("id"), index) {
                EditorField(t("字段名称", "Field label"), field.optString("label"), { change("label", it) }, vault, t, copy = false)
                EditorField(t("分组", "Group"), field.optString("group"), { change("group", it) }, vault, t, copy = false)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(t("隐藏内容", "Concealed"), Modifier.weight(1f))
                    Switch(field.optString("kind") == "concealed", { change("kind", if (it) "concealed" else "text") }, enabled = LocalEditorEnabled.current)
                }
                EditorField(t("内容", "Value"), field.optString("value"), { change("value", it) }, vault, t, secret = field.optString("kind") == "concealed", copy = false)
                TextButton(enabled = LocalEditorEnabled.current, onClick = { val next = JSONArray(fields.toString()); next.remove(index); set("customFields", next) }) { Text(t("移除字段", "Remove field")) }
            }
        }
        TextButton(enabled = LocalEditorEnabled.current && fields.length() < 256, onClick = {
            set("customFields", JSONArray(fields.toString()).put(JSONObject().put("id", java.util.UUID.randomUUID().toString()).put("label", "").put("kind", "concealed").put("value", "")))
        }) { Icon(Icons.Outlined.Add, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(t("添加字段", "Add field")) }
    }
    ImportedEditorAttachments(draft, t)
}

@Composable
private fun AlignedStructuredGroup(draft: JSONObject, vault: VaultRepository, set: (String, Any) -> Unit, t: (String, String) -> String) {
    val type = draft.optString("type")
    if (type == "identity") return IdentityDocumentEditor(draft, vault, set, t)
    if (type != "creditCard") return
    val group = draft.optJSONObject("card") ?: JSONObject()
    val standard = IdentityDocument.CORE_CARD_FIELDS
    EditorFormSection {
        EditorHeading(t("银行卡信息", "Card information"))
        standard.forEach { field ->
            EditorField(structuredFieldLabel(field, t), group.optString(field), { value ->
                set("card", JSONObject(group.toString()).put(field, value))
            }, vault, t, secret = field in listOf("number", "securityCode"), copy = false)
        }
        LegacyStructuredValues(group, group.keys().asSequence().filter { it !in standard }.sorted().toList(), vault, t)
    }
}

/** Names stay in `identity`; document data is written only to the shared `document.*` custom fields. */
@Composable
private fun IdentityDocumentEditor(draft: JSONObject, vault: VaultRepository, set: (String, Any) -> Unit, t: (String, String) -> String) {
    val group = draft.optJSONObject("identity") ?: JSONObject()
    fun identity(field: String, value: String) = set("identity", JSONObject(group.toString()).put(field, value))
    EditorFormSection {
        EditorHeading(t("证件信息", "Identity document"))
        EditorField(structuredFieldLabel("lastName", t), group.optString("lastName"), { identity("lastName", it) }, vault, t, copy = false)
        EditorField(structuredFieldLabel("firstName", t), group.optString("firstName"), { identity("firstName", it) }, vault, t, copy = false)
        IdentityDocument.FIELDS.forEach { spec ->
            val value = IdentityDocument.value(draft, spec.id)
            EditorField(IdentityDocument.label(spec.id, t), value, { next ->
                set("customFields", IdentityDocument.withValue(draft.optJSONArray("customFields"), spec.id, next))
            }, vault, t, secret = spec.kind == "concealed", copy = false)
            if (spec.kind == "date") Text(
                if (IdentityDocument.isValidDate(value.trim())) t("格式：YYYY-MM-DD", "Format: YYYY-MM-DD") else t("请输入有效日期，格式 YYYY-MM-DD", "Enter a valid date as YYYY-MM-DD"),
                Modifier.padding(start = 5.dp),
                style = MaterialTheme.typography.bodySmall,
                color = if (IdentityDocument.isValidDate(value.trim())) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
            )
        }
        LegacyStructuredValues(group, IdentityDocument.legacyIdentityKeys(group), vault, t)
    }
    EditorFormSection {
        EditorHeading(t("联系信息", "Contact details"))
        IdentityDocument.CORE_IDENTITY_FIELDS.filter { it !in setOf("lastName", "firstName") }.forEach { field ->
            EditorField(structuredFieldLabel(field, t), group.optString(field), { identity(field, it) }, vault, t, copy = false)
        }
    }
}

/** Keys the core no longer accepts for writing: displayed read-only so nothing is lost or re-sent edited. */
@Composable
private fun LegacyStructuredValues(group: JSONObject, keys: List<String>, vault: VaultRepository, t: (String, String) -> String) {
    if (keys.isEmpty()) return
    Text(t("旧版字段（只读）", "Legacy fields (read-only)"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    keys.forEach { key ->
        DetailField(structuredFieldLabel(key, t), group.optString(key), vault, t, secret = key in listOf("number", "securityCode", "pin", "documentNumber", "idNumber", "passportNumber"))
    }
}

@Composable
private fun ImportedEditorAttachments(draft: JSONObject, t: (String, String) -> String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<JSONObject?>(null) }
    var error by remember { mutableStateOf(false) }
    val export = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val attachment = pending; pending = null
        if (uri != null && attachment != null) scope.launch {
            try {
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    val bytes = android.util.Base64.decode(attachment.getString("data"), android.util.Base64.DEFAULT)
                    context.contentResolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IllegalStateException("Cannot export")
                }
            } catch (cancelled: kotlinx.coroutines.CancellationException) { throw cancelled }
            catch (_: Exception) { error = true }
        }
    }
    val attachments = draft.optJSONObject("importSource")?.optJSONArray("attachments") ?: JSONArray()
    if (attachments.length() > 0) EditorFormSection {
        EditorHeading(t("附件", "Attachments"))
        attachments.objects().forEach { attachment ->
            TextButton(enabled = LocalEditorEnabled.current, onClick = {
                pending = attachment
                export.launch(attachment.optString("name", "attachment").substringAfterLast('/').substringAfterLast('\\'))
            }) { Icon(Icons.Outlined.Description, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(attachment.optString("name")) }
        }
        if (error) Text(t("无法导出附件", "Could not export attachment"), color = MaterialTheme.colorScheme.error)
    }
}


@Composable
private fun EditorVaultDestination(draft: JSONObject, vault: VaultRepository, set: (String, Any) -> Unit, t: (String, String) -> String) {
    var open by remember { mutableStateOf(false) }
    val state by vault.state.collectAsState()
    val current = state.sharedVaults.firstOrNull { it.optString("id") == draft.optString("sharedVaultId") }
    EditorFormSection {
        Text(t("保存到", "Save to"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(onClick = { open = true }, enabled = LocalEditorEnabled.current, color = MaterialTheme.colorScheme.surface, shape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp)) {
            Row(Modifier.fillMaxWidth().heightIn(min = 50.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(current?.optString("name") ?: if (draft.optString("sharedVaultId").isBlank()) t("个人库", "Personal vault") else t("共享资料库", "Shared vault"), Modifier.weight(1f))
                Icon(Icons.Outlined.ExpandMore, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Text(t("只读共享库不可选择；权限由核心再次校验", "Read-only shared vaults cannot be selected; the core verifies permissions again"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (open) AlertDialog(onDismissRequest = { open = false }, title = { Text(t("保存到", "Save to")) }, text = {
        Column(Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
            TextButton(enabled = vault.canEdit(JSONObject().put("sharedVaultId", "")), onClick = { set("sharedVaultId", ""); open = false }, modifier = Modifier.fillMaxWidth()) { Text(t("个人库", "Personal vault"), Modifier.weight(1f)); if (draft.optString("sharedVaultId").isBlank()) Icon(Icons.Outlined.Check, null) }
            state.sharedVaults.forEach { shared ->
                val id = shared.optString("id")
                val writable = vault.canEdit(JSONObject().put("sharedVaultId", id))
                TextButton(enabled = writable, onClick = { set("sharedVaultId", id); open = false }, modifier = Modifier.fillMaxWidth()) {
                    Text(shared.optString("name") + if (writable) "" else t("（只读）", " (read-only)"), Modifier.weight(1f))
                    if (id == draft.optString("sharedVaultId")) Icon(Icons.Outlined.Check, null)
                }
            }
        }
    }, confirmButton = {}, dismissButton = { TextButton(onClick = { open = false }) { Text(t("取消", "Cancel")) } })
}
