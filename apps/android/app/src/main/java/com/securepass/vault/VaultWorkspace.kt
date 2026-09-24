package com.securepass.vault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONObject

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun VaultWorkspace(
    vault: VaultRepository,
    state: VaultState,
    t: (String, String) -> String,
    language: () -> Unit,
) {
    val wide = LocalConfiguration.current.screenWidthDp >= 600
    var page by remember {
        mutableStateOf(vault.pendingDraft?.let { JSONObject(it).optString("type") } ?: "password")
    }
    var selected by remember {
        mutableStateOf(
            vault.pendingDraft
                ?.let { JSONObject(it).optString("id") }
                ?.takeIf { id -> state.entries.any { it.optString("id") == id } }
        )
    }
    var editing by remember { mutableStateOf(vault.pendingDraft?.let(::JSONObject)) }
    var editingRestored by remember { mutableStateOf(vault.pendingDraft != null) }
    var deleting by remember { mutableStateOf<JSONObject?>(null) }
    var generator by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(state.recoveredDraft) {
        state.recoveredDraft?.let {
            editingRestored = true
            editing = JSONObject(it)
            page = JSONObject(it).optString("type")
            selected =
                JSONObject(it).optString("id").takeIf { id ->
                    state.entries.any { entry -> entry.optString("id") == id }
                }
        }
    }
    val destinations =
        linkedMapOf(
            "password" to t("账号", "Accounts"),
            "totp" to t("验证码", "Codes"),
            "crypto" to t("钱包", "Wallets"),
            "secureNote" to t("笔记", "Notes"),
            "settings" to t("设置", "Settings"),
        )
    val icons =
        listOf(
            Icons.Outlined.Key,
            Icons.Outlined.Timer,
            Icons.Outlined.AccountBalanceWallet,
            Icons.Outlined.Description,
            Icons.Outlined.Tune,
        )
    val secondary =
        mapOf(
            "trash" to t("回收站", "Trash"),
            "webdav" to "WebDAV",
            "sharing" to t("共享资料库", "Shared vaults"),
        )
    val collectionStates = remember { mutableMapOf<String, CollectionUiState>() }
    val current = state.entries.firstOrNull { it.optString("id") == selected }
    fun back() {
        selected = null
        if (page in secondary) page = "settings"
    }
    BackHandler(enabled = selected != null || page in secondary) { back() }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            if (page != "secureNote" || current != null)
                TopAppBar(
                    colors =
                        TopAppBarDefaults.topAppBarColors(
                            containerColor = MaterialTheme.colorScheme.background
                        ),
                    title = {
                        if (current != null || page in secondary)
                            Text(
                                if (current?.optString("type") == "secureNote") t("笔记", "Note")
                                else
                                    when (current?.optString("type")) {
                                        "password" -> t("账号详情", "Account details")
                                        "totp" -> t("验证码详情", "Code details")
                                        "crypto" -> t("钱包详情", "Wallet details")
                                        else -> secondary[page].orEmpty()
                                    },
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        else
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Surface(
                                    color = MaterialTheme.colorScheme.primary,
                                    shape = RoundedCornerShape(9.dp),
                                ) {
                                    Icon(
                                        Icons.Outlined.Lock,
                                        null,
                                        Modifier.padding(7.dp).size(18.dp),
                                        tint = MaterialTheme.colorScheme.onPrimary,
                                    )
                                }
                                Text("PasswordVault", style = MaterialTheme.typography.titleSmall)
                            }
                    },
                    navigationIcon = {
                        if (current != null || page in secondary)
                            IconButton(onClick = ::back) {
                                Icon(Icons.AutoMirrored.Outlined.ArrowBack, t("返回", "Back"))
                            }
                    },
                    actions = {
                        if (
                            current != null &&
                                !current.optBoolean("isDeleted") &&
                                vault.canEdit(current)
                        )
                            IconButton(
                                onClick = {
                                    editingRestored = false
                                    editing = JSONObject(current.toString())
                                }
                            ) {
                                Icon(Icons.Outlined.Edit, t("编辑", "Edit"))
                            }
                        if (current == null && page !in secondary && page != "secureNote")
                            IconButton(onClick = { generator = true }) {
                                Icon(Icons.Outlined.AutoAwesome, t("密码生成器", "Password generator"))
                            }
                        IconButton(onClick = vault::lock) {
                            Icon(Icons.Outlined.Lock, t("锁定", "Lock"))
                        }
                    },
                )
        },
        bottomBar = {
            if (!wide)
                NavigationBar(
                    containerColor = MaterialTheme.colorScheme.surface,
                    tonalElevation = 0.dp,
                ) {
                    destinations.entries.forEachIndexed { index, (type, title) ->
                        NavigationBarItem(
                            selected = page == type,
                            onClick = {
                                page = type
                                selected = null
                            },
                            icon = { Icon(icons[index], title) },
                            label = { Text(title) },
                            alwaysShowLabel = false,
                        )
                    }
                }
        },
        floatingActionButton = {
            val targetVault =
                collectionStates[page]?.vaultFilter?.value.orEmpty().let {
                    if (it == "*") "" else it
                }
            if (
                page in destinations &&
                    page != "settings" &&
                    current == null &&
                    collectionStates[page]?.selecting?.value != true &&
                    vault.canEdit(JSONObject().put("sharedVaultId", targetVault))
            )
                FloatingActionButton(
                    onClick = {
                        editingRestored = false
                        val preferences = collectionStates.getOrPut(page) { CollectionUiState() }
                        editing =
                            VaultRepository.blank(page).apply {
                                if (preferences.vaultFilter.value != "*")
                                    put("sharedVaultId", preferences.vaultFilter.value)
                                put("category", preferences.category.value)
                            }
                    },
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                    shape = RoundedCornerShape(18.dp),
                ) {
                    Icon(Icons.Outlined.Add, t("新建", "Add"))
                }
        },
    ) { padding ->
        Row(Modifier.padding(padding).fillMaxSize()) {
            if (wide)
                NavigationRail(containerColor = MaterialTheme.colorScheme.surface) {
                    destinations.entries.forEachIndexed { index, (type, title) ->
                        NavigationRailItem(
                            selected = page == type,
                            onClick = {
                                page = type
                                selected = null
                            },
                            icon = { Icon(icons[index], title) },
                            label = { Text(title) },
                        )
                    }
                }
            Column(Modifier.weight(1f).fillMaxHeight()) {
                state.notice?.let { notice ->
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            notice,
                            Modifier.weight(1f),
                            style = MaterialTheme.typography.bodySmall,
                        )
                        IconButton(onClick = vault::clearMessage) {
                            Icon(Icons.Outlined.Close, t("关闭提示", "Dismiss"))
                        }
                    }
                }
                when {
                    current?.optString("type") == "secureNote" ->
                        NoteReader(
                            current,
                            vault,
                            t,
                            { deleting = current },
                            { scope.launch { if (vault.trash(current)) selected = null } },
                        )
                    current != null ->
                        key(current.optString("id")) {
                            EntryDetail(
                                current,
                                vault,
                                t,
                                { deleting = current },
                                { scope.launch { if (vault.trash(current)) selected = null } },
                            )
                        }
                    page == "settings" ->
                        SettingsScreen(
                            vault,
                            state,
                            t,
                            language,
                            { page = "trash" },
                            { page = "webdav" },
                            { page = "sharing" },
                        )
                    page == "sharing" -> SharingScreen(vault, state, t)
                    page == "webdav" -> WebDavScreen(vault, state, t)
                    else ->
                        key(page) {
                            EntryCollection(
                                page,
                                destinations[page] ?: secondary[page].orEmpty(),
                                state,
                                vault,
                                t,
                                open = {
                                    if (
                                        !it.optBoolean("isDeleted") &&
                                            vault.canEdit(it) &&
                                            it.optString("type") in listOf("password", "crypto")
                                    ) {
                                        editingRestored = false
                                        editing = JSONObject(it.toString())
                                    } else selected = it.optString("id")
                                },
                                edit = {
                                    editingRestored = false
                                    editing = JSONObject(it.toString())
                                },
                                delete = { deleting = it },
                                manageCategories = { page = "settings" },
                                ui = collectionStates.getOrPut(page) { CollectionUiState() },
                                operationScope = scope,
                            )
                        }
                }
            }
        }
    }
    editing?.let {
        EntryEditor(it, vault, t, restoredDraft = editingRestored) {
            if (it.optString("type") != "secureNote") selected = null
            editing = null
            editingRestored = false
        }
    }
    if (generator) QuickGenerator(vault, t) { generator = false }
    deleting?.let { target ->
        AlertDialog(
            onDismissRequest = { if (!state.busy) deleting = null },
            title = {
                Text(
                    if (target.optBoolean("isDeleted")) t("永久删除？", "Delete permanently?")
                    else t("移到回收站？", "Move to Trash?")
                )
            },
            text = { Text(target.optString("title")) },
            confirmButton = {
                TextButton(
                    enabled = !state.busy,
                    onClick = {
                        scope.launch {
                            val ok =
                                if (target.optBoolean("isDeleted")) vault.remove(target)
                                else vault.trash(target)
                            if (ok) {
                                deleting = null
                                if (selected == target.optString("id")) selected = null
                            }
                        }
                    },
                ) {
                    Text(t("删除", "Delete"), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(enabled = !state.busy, onClick = { deleting = null }) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
    }
}

@Composable
private fun QuickGenerator(
    vault: VaultRepository,
    t: (String, String) -> String,
    close: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = close,
        title = { Text(t("密码生成器", "Password generator")) },
        text = { PasswordGeneratorControls(vault, t) },
        confirmButton = { TextButton(onClick = close) { Text(t("关闭", "Close")) } },
    )
}
