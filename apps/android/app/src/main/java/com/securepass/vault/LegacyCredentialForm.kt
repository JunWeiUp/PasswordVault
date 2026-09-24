package com.securepass.vault

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

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun LegacyCredentialForm(
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
                val parsed = vault.command("parse-totp", JSONObject().put("uri", value))
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
        EditorHeading(t("基本信息", "Basic information"))
        EditorField(
            if (kind == "crypto") t("钱包名称", "Wallet name") else t("账号名称", "Account name"),
            draft.optString("title"),
            { set("title", it) },
            vault,
            t,
            copy = false,
        )
        if (kind != "crypto")
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
        ChoiceEditor(
            t("分类", "Category"),
            draft.optString("category"),
            (legacyCategories + vault.state.value.entries.map { it.optString("category") })
                .filter { it.isNotBlank() }
                .distinct(),
            t,
        ) {
            set("category", it)
        }
        if (vault.state.value.sharedVaults.isNotEmpty()) {
            Text(t("所属资料库", "Vault"), style = MaterialTheme.typography.labelLarge)
            FilterChip(
                selected = draft.optString("sharedVaultId").isEmpty(),
                onClick = { set("sharedVaultId", "") },
                enabled = enabled,
                label = { Text(t("个人资料库", "Personal vault")) },
            )
            vault.state.value.sharedVaults.forEach { shared ->
                val writable =
                    vault.canEdit(JSONObject().put("sharedVaultId", shared.optString("id")))
                FilterChip(
                    selected = draft.optString("sharedVaultId") == shared.optString("id"),
                    onClick = { set("sharedVaultId", shared.optString("id")) },
                    enabled = enabled && writable,
                    label = {
                        Text(
                            shared.optString("name") +
                                if (writable) "" else t(" · 只读", " · Read only")
                        )
                    },
                )
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
        if (kind == "password")
            EditorFormSection {
                EditorHeading(t("二次验证", "Two-step verification"))
                Text(
                    if (draft.optString("secret").isBlank()) t("未配置", "Not configured")
                    else t("已配置", "Configured")
                )
                EditorActionButton(
                    enabled = enabled,
                    onClick = {
                        secretInput = draft.optString("secret")
                        twoFactor = true
                    },
                ) {
                    Text(t("配置二次验证", "Configure two-step verification"))
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
        EditorHeading(t("可选信息", "Optional information"))
        if (kind != "crypto") {
            EditorField(t("邮箱", "Email"), draft.optString("email"), { set("email", it) }, vault, t)
            EditorField(
                t("网站 / 域名", "Websites / domains"),
                draft.optString("url"),
                { set("url", it) },
                vault,
                t,
                lines = 2,
            )
        }
        EditorField(
            t("备注", "Notes"),
            draft.optString("note"),
            { set("note", it) },
            vault,
            t,
            lines = 3,
        )
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
    }
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
    if (twoFactor)
        AlertDialog(
            onDismissRequest = { twoFactor = false },
            title = { Text(t("配置二次验证", "Configure two-step verification")) },
            text = {
                EditorField(
                    t("设置密钥", "Setup key"),
                    secretInput,
                    { secretInput = it },
                    vault,
                    t,
                    secret = true,
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        set("secret", secretInput.filterNot { it.isWhitespace() }.uppercase())
                        twoFactor = false
                    }
                ) {
                    Text(t("确认", "Confirm"))
                }
            },
            dismissButton = {
                Row {
                    TextButton(
                        onClick = {
                            set("secret", "")
                            twoFactor = false
                        }
                    ) {
                        Text(t("清除", "Clear"))
                    }
                    TextButton(onClick = { twoFactor = false }) { Text(t("取消", "Cancel")) }
                }
            },
        )
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
    copy: Boolean = true,
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
        Column {
            TextField(
                value,
                change,
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = label },
                enabled = enabled,
                singleLine = lines == 1,
                minLines = lines,
                label = { Text(label) },
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
                    TextFieldDefaults.colors(
                        focusedContainerColor = accountFieldColor(),
                        unfocusedContainerColor = accountFieldColor(),
                        disabledContainerColor = accountFieldColor(),
                        unfocusedIndicatorColor = Color.Transparent,
                        disabledIndicatorColor = Color.Transparent,
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
                Text(
                    "$label · " + value.ifEmpty { t("无", "None") },
                    Modifier.weight(1f),
                    style = MaterialTheme.typography.bodyMedium,
                )
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
        TextButton(onClick = { revealed = !revealed }) {
            Text(
                if (revealed) t("隐藏助记词", "Hide recovery phrase")
                else t("显示助记词", "Show recovery phrase")
            )
        }
        TextButton(enabled = enabled, onClick = { paste = !paste }) {
            Text(t("粘贴整段", "Paste phrase"))
        }
        IconButton(enabled = value.isNotBlank(), onClick = { vault.copy(value) }) {
            Icon(Icons.Outlined.ContentCopy, t("复制助记词", "Copy recovery phrase"))
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
