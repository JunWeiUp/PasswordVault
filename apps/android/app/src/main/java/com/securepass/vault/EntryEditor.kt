package com.securepass.vault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EntryEditor(
    original: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    restoredDraft: Boolean = false,
    openGenerator: Boolean = false,
    close: () -> Unit,
) {
    val state by vault.state.collectAsState()
    val existing = state.entries.any { it.optString("id") == original.optString("id") }
    if (original.optString("type") == "secureNote") {
        val rich = remember(original.optString("id")) { original.optString("noteFormat") == "rich-v1" || (!existing && !restoredDraft) }
        if (rich) RichNoteEditor(original, vault, t, close)
        else NoteEditor(original, vault, t, restoredDraft, close)
        return
    }
    if (original.optString("type") == "device") {
        DeviceEditor(original, vault, t, restoredDraft, close)
        return
    }
    var draftText by remember { mutableStateOf(original.toString()) }
    val draft = JSONObject(draftText)
    val type = draft.optString("type")
    var saving by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    var walletSource by remember {
        mutableStateOf(
            original.optString("_walletEditSource").takeIf {
                it in listOf("privateKey", "mnemonic")
            }
        )
    }
    val walletRequests = remember { WalletEditRequests(if (walletSource == null) 0 else 1) }
    val walletRevision by walletRequests.revision
    var derivedRevision by remember { mutableIntStateOf(0) }
    var deriving by remember { mutableStateOf(false) }
    val busy = saving || working
    var discard by remember { mutableStateOf(false) }
    var replace by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // Null while closed; "" targets the main password, otherwise an additional account's ID.
    var generatorFor by remember { mutableStateOf(if (openGenerator && type == "password") "" else null) }
    var saveFailed by remember { mutableStateOf(false) }
    var failureKind by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(error) {
        error?.let { snackbar.showSnackbar(it, duration = SnackbarDuration.Long) }
    }
    fun set(key: String, value: Any) {
        draftText = JSONObject(draftText).put(key, value).toString()
        if (type == "crypto") {
            if (key in listOf("privateKey", "mnemonic")) {
                walletSource = key
                draftText = JSONObject(draftText).put("_walletEditSource", key).toString()
                walletRequests.begin()
            } else if (key in listOf("address", "network")) {
                walletSource = null
                draftText = JSONObject(draftText).apply { remove("_walletEditSource") }.toString()
                deriving = false
                walletRequests.begin()
                derivedRevision = walletRevision
            }
        }
        vault.pendingDraft = draftText
        vault.activity()
    }
    LaunchedEffect(walletRevision) {
        val source = walletSource ?: return@LaunchedEffect
        val revision = walletRevision
        try {
            delay(500)
            val current = JSONObject(draftText)
            if (
                current.optString("network") !in
                    listOf("", "ETH", "BSC", "Polygon", "AVAX", "Arbitrum", "Optimism")
            )
                return@LaunchedEffect
            if (current.optString(source).isBlank()) return@LaunchedEffect
            deriving = true
            val result =
                vault.command(
                    "wallet",
                    JSONObject()
                        .put("generate", false)
                        .put(
                            "mnemonic",
                            if (source == "mnemonic")
                                current
                                    .optString("mnemonic")
                                    .trim()
                                    .split(Regex("\\s+"))
                                    .joinToString(" ")
                            else "",
                        )
                        .put("privateKey", current.optString("privateKey")),
                )
            if (walletRequests.owns(revision) && !saving && !working) {
                val next = JSONObject(draftText)
                next.remove("_walletEditSource")
                next.put("address", result.getString("address"))
                if (source == "mnemonic") next.put("privateKey", result.getString("privateKey"))
                if (next.optString("network").isBlank()) next.put("network", "ETH")
                draftText = next.toString()
                vault.pendingDraft = draftText
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            /* An incomplete edit does not overwrite the last valid credentials. */
        } finally {
            if (walletRequests.owns(revision)) {
                derivedRevision = revision
                deriving = false
            }
        }
    }
    fun cancel() {
        if (busy) return
        if (
            restoredDraft ||
                draftText != original.toString() ||
                vault.state.value.recoveredDraft != null
        )
            discard = true
        else {
            vault.discardDraft()
            close()
        }
    }
    fun save() {
        if (busy || walletRevision != derivedRevision) return
        val submitted = JSONObject(draftText).apply { remove("_walletEditSource") }
        if (submitted.optString("title").isBlank()) {
            error = t("请填写名称", "Enter a name")
            return
        }
        if (type == "identity" && IdentityDocument.invalidDates(submitted).isNotEmpty()) {
            error = t("证件日期格式应为 YYYY-MM-DD", "Document dates must use YYYY-MM-DD")
            return
        }
        val accounts = submitted.optJSONArray("accounts")?.objects().orEmpty()
        if (
            accounts.any {
                it.optString("username").isBlank() &&
                    (it.optString("password").isNotEmpty() || it.optString("label").isNotBlank())
            }
        ) {
            error =
                t("请填写附加账号的用户名，或移除该账号。", "Enter the additional username or remove that account.")
            return
        }
        if (type in listOf("password", "totp"))
            submitted.put(
                "accounts",
                JSONArray(accounts.filter { it.optString("username").isNotBlank() }),
            )
        saving = true
        error = null
        saveFailed = false
        scope.launch {
            try {
                val secret = submitted.optString("secret")
                if (
                    type == "totp" ||
                        (secret.isNotBlank() && secret != original.optString("secret"))
                ) {
                    vault.command(
                        "totp",
                        JSONObject()
                            .put("secret", secret)
                            .put("period", submitted.optInt("period", 30))
                            .put("time", System.currentTimeMillis() / 1000),
                    )
                }
                if (vault.save(prepareEntrySave(submitted, vault.state.value.entries))) {
                    vault.discardDraft()
                    close()
                } else {
                    failureKind = vault.lastFailureKind
                    saveFailed = true
                    // The inline banner replaces the global error dialog for this failure.
                    vault.clearMessage()
                }
            } catch (_: Exception) {
                error = t("内容无效，请检查密钥和间隔", "Invalid content; check the setup key and period")
            } finally {
                saving = false
            }
        }
    }
    fun generate(accountId: String?) {
        if (busy) return
        generatorFor = accountId ?: ""
    }
    fun useGenerated(password: String) {
        val target = generatorFor ?: return
        generatorFor = null
        if (target.isEmpty()) set("password", password)
        else {
            val accounts = JSONArray(JSONObject(draftText).optJSONArray("accounts")?.toString() ?: "[]")
            accounts.objects().firstOrNull { it.optString("id") == target }?.put("password", password)
            set("accounts", accounts)
        }
        scope.launch { snackbar.showSnackbar(t("已填入新密码，记得保存", "New password filled in; remember to save")) }
    }
    fun copyFailureDetails() {
        vault.copy(saveFailureDetails(failureKind, type, existing, android.os.Build.VERSION.SDK_INT, BuildConfig.VERSION_NAME))
    }
    fun wallet(generate: Boolean, source: String = "mnemonic") {
        if (busy) return
        // Explicit generation/derivation owns a new revision. Older queued automatic results
        // may finish after the native call, but can no longer update this draft.
        walletRequests.begin()
        derivedRevision = walletRevision
        walletSource = null
        deriving = false
        draftText = JSONObject(draftText).apply { remove("_walletEditSource") }.toString()
        vault.pendingDraft = draftText
        working = true
        scope.launch {
            try {
                val current = JSONObject(draftText)
                val result =
                    vault.command(
                        "wallet",
                        JSONObject()
                            .put("generate", generate)
                            .put(
                                "mnemonic",
                                if (source == "mnemonic" || generate) current.optString("mnemonic")
                                else "",
                            )
                            .put("privateKey", current.optString("privateKey")),
                    )
                val next = JSONObject(draftText).apply { remove("_walletEditSource") }
                (if (!generate && source == "privateKey") listOf("network", "address")
                    else listOf("network", "address", "privateKey", "mnemonic"))
                    .forEach { if (result.optString(it).isNotEmpty()) next.put(it, result.get(it)) }
                draftText = next.toString()
                vault.pendingDraft = draftText
                vault.activity()
            } catch (_: Exception) {
                error = t("钱包凭据格式无效", "Invalid wallet credentials")
            } finally {
                working = false
            }
        }
    }
    if (type == "totp" && !existing) ModalBottomSheet(
        onDismissRequest = ::cancel,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { target ->
            if (target == SheetValue.Hidden && (saving || working)) false
            else if (target == SheetValue.Hidden && (restoredDraft || draftText != original.toString() || vault.state.value.recoveredDraft != null)) { discard = true; false }
            else true
        }),
        containerColor = MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).imePadding(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(t("手动输入密钥", "Enter secret manually"), style = MaterialTheme.typography.titleLarge)
            if (saveFailed) SaveFailureBanner(existing, t, ::save, ::copyFailureDetails, enabled = !busy, stale = failureKind == "StaleEdit")
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            EditorField(t("发行方", "Issuer"), draft.optString("title"), { set("title", it); set("issuer", it) }, vault, t, copy = false)
            EditorField(t("账号", "Account"), draft.optString("username"), { set("username", it) }, vault, t, copy = false)
            EditorField(t("密钥（Base32）", "Secret (Base32)"), draft.optString("secret"), { set("secret", it.filterNot { char -> char.isWhitespace() }.uppercase()) }, vault, t, secret = true, copy = false)
            Text(t("通常为 6 位、30 秒。添加前会验证密钥格式。", "Usually 6 digits, every 30 seconds. The secret is validated before saving."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(enabled = !busy, onClick = ::cancel) { Text(t("取消", "Cancel")) }
                Button(enabled = !busy && draft.optString("title").isNotBlank() && draft.optString("secret").isNotBlank(), onClick = ::save) { Text(t("添加", "Add")) }
            }
            Spacer(Modifier.height(20.dp))
        }
    } else Dialog(
        onDismissRequest = ::cancel,
        properties =
            DialogProperties(
                usePlatformDefaultWidth = false,
                dismissOnBackPress = false,
                securePolicy = androidx.compose.ui.window.SecureFlagPolicy.Inherit,
                decorFitsSystemWindows = false,
            ),
    ) {
        EditorDialogBars()
        BackHandler(onBack = ::cancel)
        CompositionLocalProvider(
            LocalEditorEnabled provides !busy,
            LocalAccountForm provides true,
        ) {
            Scaffold(
                containerColor = MaterialTheme.colorScheme.background,
                snackbarHost = { SnackbarHost(snackbar) },
                topBar = {
                    TopAppBar(
                        expandedHeight = 55.dp,
                        colors =
                            TopAppBarDefaults.topAppBarColors(
                                containerColor = MaterialTheme.colorScheme.surface
                            ),
                        title = {
                            Text(
                                when (type) {
                                    "creditCard" -> if (existing) t("编辑钱包 · 银行卡", "Edit wallet · Payment card") else t("新建钱包 · 银行卡", "New wallet · Payment card")
                                    "identity" -> if (existing) t("编辑钱包 · 证件", "Edit wallet · Identity") else t("新建钱包 · 证件", "New wallet · Identity")
                                    "crypto" ->
                                        if (existing) t("编辑钱包", "Edit wallet")
                                        else t("添加钱包", "Add wallet")
                                    "totp" ->
                                        if (existing) t("编辑验证码", "Edit code")
                                        else t("添加验证码", "Add code")
                                    else ->
                                        if (existing) t("编辑账号", "Edit account")
                                        else t("添加账号", "Add account")
                                },
                                style =
                                    if (type == "password") MaterialTheme.typography.titleLarge
                                    else LocalTextStyle.current,
                                maxLines = if (type == "password") 1 else Int.MAX_VALUE,
                                overflow =
                                    if (type == "password")
                                        androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                    else androidx.compose.ui.text.style.TextOverflow.Clip,
                            )
                        },
                        navigationIcon = {
                            IconButton(enabled = !busy, onClick = ::cancel) {
                                Icon(Icons.Outlined.Close, t("关闭", "Close"))
                            }
                        },
                        actions = {
                            Button(
                                enabled = !busy && walletRevision == derivedRevision && draft.optString("title").isNotBlank(),
                                onClick = ::save,
                                modifier = Modifier.padding(end = 12.dp).heightIn(min = 40.dp),
                                contentPadding = PaddingValues(horizontal = 18.dp, vertical = 8.dp),
                                shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
                            ) { Text(if (saving) t("保存中…", "Saving…") else t("保存", "Save")) }
                        },
                    )
                },
            ) { padding ->
                Column(
                    Modifier.padding(padding)
                        .imePadding()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 11.dp)
                        .padding(top = 8.dp, bottom = 16.dp),
                    verticalArrangement =
                        Arrangement.spacedBy(18.dp),
                ) {
                    if (saveFailed) SaveFailureBanner(existing, t, ::save, ::copyFailureDetails, enabled = !busy, stale = failureKind == "StaleEdit")
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    if (working || deriving) LinearProgressIndicator(Modifier.fillMaxWidth())
                    LegacyCredentialForm(
                        draft,
                        vault,
                        t,
                        ::set,
                        ::generate,
                        deriveWallet = { wallet(false, it) },
                        generateWallet = {
                            if (
                                listOf("address", "privateKey", "mnemonic").any {
                                    draft.optString(it).isNotBlank()
                                }
                            )
                                replace = true
                            else wallet(true)
                        },
                        report = { error = it },
                        busyChanged = { working = it },
                    )
                    PasskeyRecordsPanel(vault.state.value.entries.firstOrNull { it.optString("id") == draft.optString("id") } ?: draft, vault, t) { removed ->
                        val next = JSONObject(draftText); val keys = next.optJSONArray("passkeys") ?: JSONArray(); val remaining = JSONArray()
                        for (index in 0 until keys.length()) if (keys.getJSONObject(index).optString("credentialId") != removed) remaining.put(keys.getJSONObject(index))
                        next.put("passkeys", remaining); draftText = next.toString()
                    }
                    AlignedStructuredFieldsEditor(draft, vault, ::set, t)
                    if (existing)
                        OutlinedButton(
                            enabled = !busy,
                            onClick = { deleting = true },
                            modifier = Modifier.fillMaxWidth(),
                            colors =
                                ButtonDefaults.outlinedButtonColors(
                                    contentColor = MaterialTheme.colorScheme.error
                                ),
                        ) {
                            Text(t("移到回收站…", "Move to Trash…"))
                        }
                    Spacer(Modifier.height(24.dp))
                }
            }
        }
    }
    if (generatorFor != null)
        AlertDialog(
            onDismissRequest = { generatorFor = null },
            title = { Text(t("密码生成器", "Password generator")) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PasswordGeneratorControls(vault, t, onUse = ::useGenerated)
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { generatorFor = null }) { Text(t("取消", "Cancel")) } },
        )
    if (discard)
        AlertDialog(
            onDismissRequest = { discard = false },
            title = { Text(t("保存这次修改？", "Save your changes?")) },
            text = {
                Text(t("返回前保存修改，或放弃这次编辑。", "Save before returning, or discard this edit."))
            },
            confirmButton = {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        discard = false
                        save()
                    },
                ) {
                    Text(t("保存", "Save"))
                }
            },
            dismissButton = {
                Row {
                    TextButton(
                        enabled = !busy,
                        onClick = {
                            vault.discardDraft()
                            close()
                        },
                    ) {
                        Text(t("放弃修改", "Discard"))
                    }
                    TextButton(onClick = { discard = false }) {
                        Text(t("继续编辑", "Keep editing"))
                    }
                }
            },
        )
    if (replace)
        AlertDialog(
            onDismissRequest = { replace = false },
            title = { Text(t("替换草稿中的钱包凭据？", "Replace draft wallet credentials?")) },
            text = { Text(t("保存前不修改原记录。", "The original record changes only when saved.")) },
            confirmButton = {
                TextButton(
                    onClick = {
                        replace = false
                        wallet(true)
                    }
                ) {
                    Text(t("生成并替换", "Generate and replace"))
                }
            },
            dismissButton = {
                TextButton(onClick = { replace = false }) { Text(t("取消", "Cancel")) }
            },
        )
    if (deleting)
        AlertDialog(
            onDismissRequest = { deleting = false },
            title = { Text(t("移到回收站？", "Move to Trash?")) },
            text = {
                Text(
                    t(
                        "未保存的修改不会保存。条目可从回收站恢复。",
                        "Unsaved changes will be discarded. The record can be restored from Trash.",
                    )
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        saving = true
                        scope.launch {
                            val persisted =
                                vault.state.value.entries.firstOrNull {
                                    it.optString("id") == original.optString("id")
                                }
                            if (persisted != null && vault.trash(persisted)) {
                                vault.discardDraft()
                                close()
                            }
                            saving = false
                        }
                    },
                ) {
                    Text(t("删除", "Delete"))
                }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { deleting = false }) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
}
