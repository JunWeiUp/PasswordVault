package com.securepass.vault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
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
    val context = androidx.compose.ui.platform.LocalContext.current
    // Settings › General › Show on open picks the first bottom destination after unlocking.
    val startPage = remember { AppPreferences.startPage(context) }
    var page by rememberSaveable {
        mutableStateOf(vault.pendingDraft?.let { workspaceDestination(JSONObject(it).optString("type")) } ?: startPage)
    }
    var root by rememberSaveable { mutableStateOf(startPage) }
    LaunchedEffect(root) { AppPreferences.rememberLastPage(context, root) }
    val drawer = rememberDrawerState(DrawerValue.Closed)
    var detailMenu by remember { mutableStateOf(false) }
    var selected by rememberSaveable {
        mutableStateOf(
            vault.pendingDraft
                ?.let { JSONObject(it).optString("id") }
                ?.takeIf { id -> state.entries.any { it.optString("id") == id } }
        )
    }
    var editing by remember { mutableStateOf(vault.pendingDraft?.let(::JSONObject)) }
    var editingRestored by remember { mutableStateOf(vault.pendingDraft != null) }
    var editingGenerator by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<JSONObject?>(null) }
    var createChooser by remember { mutableStateOf(false) }
    var codeChooser by remember { mutableStateOf(false) }
    var codeCamera by remember { mutableStateOf(false) }
    var generator by remember { mutableStateOf(false) }
    var settingsSubpage by remember { mutableStateOf(false) }
    var settingsStart by remember { mutableStateOf("home") }
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }
    if (createChooser && vault.canWriteLibrary()) VaultActionSheet(t("新建钱包项目", "New wallet item"), "", { createChooser = false }) {
        for ((kind, label) in listOf("creditCard" to t("银行卡", "Payment card"), "identity" to t("身份证件", "Identity"), "crypto" to t("加密货币钱包", "Crypto wallet"))) {
            ListItem(headlineContent = { Text(label) }, leadingContent = { Icon(when (kind) { "creditCard" -> Icons.Outlined.CreditCard; "identity" -> Icons.Outlined.Badge; else -> Icons.Outlined.CurrencyBitcoin }, null) }, modifier = Modifier.clickable { createChooser = false; editingRestored = false; editing = VaultRepository.blank(kind) })
        }
    }
    if (codeChooser && vault.canWriteLibrary()) VaultActionSheet(t("添加验证码", "Add authenticator code"), t("扫描网站提供的二维码，或手动输入密钥。", "Scan a QR code or enter the secret manually."), { codeChooser = false }) {
        Button(onClick = { codeChooser = false; codeCamera = true }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text(t("扫描二维码", "Scan QR code")) }
        OutlinedButton(onClick = { codeChooser = false; editingRestored = false; editing = VaultRepository.blank("totp") }, modifier = Modifier.fillMaxWidth()) { Text(t("手动输入密钥", "Enter secret manually")) }
    }
    if (codeCamera) LiveQrScanner(vault, t, { uri ->
        codeCamera = false
        scope.launch {
            try {
                val parsed = vault.command(CoreRequest.parseTotp(uri))
                editingRestored = false
                editing = VaultRepository.blank("totp").apply {
                    put("title", parsed.optString("issuer").ifBlank { parsed.optString("account") })
                    put("issuer", parsed.optString("issuer")); put("username", parsed.optString("account")); put("secret", parsed.getString("secret")); put("period", parsed.optInt("period", 30))
                }
            } catch (_: Exception) { vault.report() }
        }
    }, { codeCamera = false })

    LaunchedEffect(state.recoveredDraft) {
        state.recoveredDraft?.let {
            editingRestored = true
            editing = JSONObject(it)
            page = workspaceDestination(JSONObject(it).optString("type"))
            selected =
                JSONObject(it).optString("id").takeIf { id ->
                    state.entries.any { entry -> entry.optString("id") == id }
                }
        }
    }
    val destinations =
        linkedMapOf(
            "secureNote" to t("笔记", "Notes"),
            "password" to t("账号", "Accounts"),
            "totp" to t("验证码", "Codes"),
            "wallets" to t("钱包", "Wallets"),
            "settings" to t("设置", "Settings"),
        )
    val icons =
        listOf(
            Icons.Outlined.Description,
            Icons.Outlined.Key,
            Icons.Outlined.Timer,
            Icons.Outlined.AccountBalanceWallet,
            Icons.Outlined.Tune,
        )
    val secondary = linkedMapOf(
        "all" to t("全部项目", "All items"),
        "favorites" to t("个人收藏", "Favorites"),
        "device" to t("设备与服务", "Devices & services"),
        "trash" to t("回收站", "Trash"),
        "webdav" to "WebDAV",
        "relay" to t("同步与设备", "Sync & devices"),
    )
    val collectionStates = remember { mutableMapOf<String, CollectionUiState>() }
    val current = state.entries.firstOrNull { it.optString("id") == selected }
    fun back() {
        if (selected != null) selected = null
        else if (page in secondary) page = root
    }
    BackHandler(enabled = selected != null || page in secondary) { back() }
    BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
    ModalNavigationDrawer(
        drawerState = drawer,
        gesturesEnabled = editing == null && current == null,
        drawerContent = {
            ModalDrawerSheet(modifier = Modifier.width((LocalConfiguration.current.screenWidthDp * .82f).dp).verticalScroll(rememberScrollState()), drawerContainerColor = MaterialTheme.colorScheme.surface, drawerShape = RoundedCornerShape(topEnd = 18.dp, bottomEnd = 18.dp)) {
                Row(Modifier.padding(horizontal = 24.dp, vertical = 18.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Surface(shape = RoundedCornerShape(20.dp), color = MaterialTheme.colorScheme.primary) { Icon(Icons.Outlined.Shield, null, Modifier.padding(8.dp).size(20.dp), tint = MaterialTheme.colorScheme.onPrimary) }
                    Text("PasswordVault", style = MaterialTheme.typography.titleMedium)
                }
                @Composable fun drawerItem(destination: String, label: String, icon: androidx.compose.ui.graphics.vector.ImageVector) {
                    NavigationDrawerItem(label = { Text(label) }, selected = page == destination,
                        icon = { Icon(icon, null, Modifier.size(22.dp)) }, badge = { Text("${state.entries.count { matchesWorkspaceDestination(it, destination) }}", style = MaterialTheme.typography.bodySmall) },
                        modifier = Modifier.padding(horizontal = 12.dp).height(48.dp), onClick = {
                            page = destination; selected = null; settingsStart = "home"
                            if (destination in destinations) root = destination
                            scope.launch { drawer.close() }
                        })
                }
                drawerItem("all", secondary.getValue("all"), Icons.Outlined.GridView)
                drawerItem("favorites", secondary.getValue("favorites"), Icons.Outlined.StarOutline)
                HorizontalDivider(Modifier.padding(horizontal = 24.dp, vertical = 10.dp))
                destinations.entries.filter { it.key != "settings" }.forEach { (destination, label) -> drawerItem(destination, label, icons[destinations.keys.indexOf(destination)]) }
                drawerItem("device", secondary.getValue("device"), Icons.Outlined.Dns)
                HorizontalDivider(Modifier.padding(horizontal = 24.dp, vertical = 10.dp))
                Text(t("笔记分类", "Note categories"), Modifier.padding(start = 26.dp, bottom = 6.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                val noteCategories = (state.settings.optJSONArray("noteCategories")?.let { a -> (0 until a.length()).map { a.optString(it) } }.orEmpty() + state.entries.filter { it.optString("type") == "secureNote" && !it.optBoolean("isDeleted") }.map { it.optString("category") }).filter { it.isNotBlank() }.distinct().sorted()
                noteCategories.forEach { name -> NavigationDrawerItem(label = { Text(name) }, selected = false, icon = { Icon(Icons.Outlined.FolderOpen, null) }, badge = { Text("${state.entries.count { it.optString("type") == "secureNote" && !it.optBoolean("isDeleted") && it.optString("category") == name }}", style = MaterialTheme.typography.bodySmall) }, modifier = Modifier.padding(horizontal = 12.dp).height(48.dp), onClick = {
                    collectionStates.getOrPut("secureNote") { CollectionUiState() }.category.value = name; page = "secureNote"; root = page; selected = null; scope.launch { drawer.close() }
                }) }
                HorizontalDivider(Modifier.padding(horizontal = 24.dp, vertical = 10.dp))
                Text(t("工具", "Tools"), Modifier.padding(start = 26.dp, bottom = 6.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                NavigationDrawerItem(label = { Text(t("密码生成器", "Password generator")) }, selected = false, icon = { Icon(Icons.Outlined.AutoAwesome, null) }, modifier = Modifier.padding(horizontal = 12.dp).height(48.dp), onClick = { settingsStart = "generator"; page = "settings"; scope.launch { drawer.close() } })
                NavigationDrawerItem(label = { Text(t("密码健康", "Password health")) }, selected = false, icon = { Icon(Icons.Outlined.Shield, null) }, modifier = Modifier.padding(horizontal = 12.dp).height(48.dp), onClick = { settingsStart = "health"; page = "settings"; scope.launch { drawer.close() } })
                drawerItem("trash", secondary.getValue("trash"), Icons.Outlined.DeleteOutline)
                HorizontalDivider(Modifier.padding(horizontal = 24.dp, vertical = 10.dp))
                NavigationDrawerItem(label = { Text(t("立即锁定", "Lock now")) }, selected = false, icon = { Icon(Icons.Outlined.Lock, null) }, modifier = Modifier.padding(horizontal = 12.dp).height(48.dp), onClick = vault::lock)
                Spacer(Modifier.height(20.dp))
            }
        },
    ) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            if (current != null || page in setOf("relay", "webdav")) TopAppBar(
                expandedHeight = 55.dp,
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
                title = { if (current == null) Text(secondary[page].orEmpty(), style = MaterialTheme.typography.titleLarge) },
                navigationIcon = { IconButton(onClick = ::back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, t("返回", "Back")) } },
                actions = {
                    if (current != null) {
                        if (!current.optBoolean("isDeleted") && vault.canEdit(current)) {
                            if (current.optString("type") == "secureNote") IconButton(onClick = { scope.launch { vault.save(JSONObject(current.toString()).put("isPinned", !current.optBoolean("isPinned"))) } }) {
                                Icon(Icons.Outlined.PushPin, t("置顶", "Pin"), tint = if (current.optBoolean("isPinned")) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(onClick = { scope.launch { vault.save(JSONObject(current.toString()).put("isFavorite", !current.optBoolean("isFavorite"))) } }) {
                                Icon(if (current.optBoolean("isFavorite")) Icons.Outlined.Star else Icons.Outlined.StarOutline, t("收藏", "Favorite"), tint = if (current.optBoolean("isFavorite")) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            if (current.optString("type") != "secureNote" && (current.optString("type") != "device" || DevicePayload.editable(current, true))) IconButton(onClick = { editingRestored = false; editing = JSONObject(current.toString()) }) { Icon(Icons.Outlined.Edit, t("编辑", "Edit")) }
                        }
                        IconButton(onClick = { detailMenu = true }) { Icon(Icons.Outlined.MoreHoriz, t("更多操作", "More actions")) }
                    }
                },
            )
        },
        bottomBar = {
            if (!wide && current == null && editing == null && !settingsSubpage && page !in setOf("relay", "webdav"))
                NavigationBar(
                    containerColor = MaterialTheme.colorScheme.surface,
                    tonalElevation = 0.dp,
                    modifier = Modifier.height(68.dp),
                    windowInsets = WindowInsets(0, 0, 0, 0),
                ) {
                    destinations.entries.forEachIndexed { index, (type, title) ->
                        NavigationBarItem(
                            modifier = Modifier.semantics { contentDescription = title },
                            selected = page == type,
                            onClick = {
                                settingsStart = "home"
                                page = type
                                root = type
                                selected = null
                            },
                            icon = { Icon(icons[index], null, Modifier.size(22.dp)) },
                            label = { Text(title, style = MaterialTheme.typography.labelSmall) },
                            alwaysShowLabel = true,
                        )
                    }
                }
        },
        floatingActionButton = {
            if (current?.optString("type") == "secureNote" && !current.optBoolean("isDeleted") && vault.canEdit(current)) ExtendedFloatingActionButton(
                onClick = { editingRestored = false; editing = JSONObject(current.toString()) },
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.primary,
                shape = RoundedCornerShape(16.dp),
            ) { Icon(Icons.Outlined.Edit, null); Spacer(Modifier.width(8.dp)); Text(t("编辑", "Edit")) }
            if (page == "device" && current == null && DevicePayload.canCreate(state.settings, vault.canWriteLibrary()))
                ExtendedFloatingActionButton(
                    onClick = { editingRestored = false; editing = DevicePayload.blank() },
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    shape = RoundedCornerShape(18.dp),
                ) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text(t("新建", "New")) }
            if (
                vault.canWriteLibrary() && (page in destinations || page == "all") &&
                    page != "settings" &&
                    current == null &&
                    collectionStates[page]?.selecting?.value != true
            )
                ExtendedFloatingActionButton(
                    onClick = {
                        if (page == "wallets") { createChooser = true } else if (page == "totp") { codeChooser = true } else {
                        editingRestored = false
                        val preferences = collectionStates.getOrPut(page) { CollectionUiState() }
                        editing =
                            VaultRepository.blank(if (page == "all") "password" else page).apply {
                                put("category", preferences.category.value)
                            }
                        }
                    },
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                    shape = RoundedCornerShape(18.dp),
                ) {
                    Icon(if (page == "totp") Icons.Outlined.QrCodeScanner else Icons.Outlined.Add, null)
                    Spacer(Modifier.width(8.dp))
                    Text(if (page == "totp") t("添加", "Add") else t("新建", "New"))
                }
        },
    ) { padding ->
        Row(Modifier.padding(padding).fillMaxSize()) {
            if (wide && current == null && editing == null && !settingsSubpage)
                NavigationRail(containerColor = MaterialTheme.colorScheme.surface) {
                    destinations.entries.forEachIndexed { index, (type, title) ->
                        NavigationRailItem(
                            modifier = Modifier.semantics { contentDescription = title },
                            selected = page == type,
                            onClick = {
                                settingsStart = "home"
                                page = type
                                root = type
                                selected = null
                            },
                            icon = { Icon(icons[index], null, Modifier.size(22.dp)) },
                            label = { Text(title, style = MaterialTheme.typography.labelSmall) },
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
                                generatePassword = {
                                    editingRestored = false
                                    editingGenerator = true
                                    editing = JSONObject(current.toString())
                                },
                                openHealth = { selected = null; settingsStart = "health"; page = "settings" },
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
                            { page = "relay" },
                            openNavigation = { scope.launch { drawer.open() } },
                            onSubpageChanged = { settingsSubpage = it },
                            initialPage = settingsStart,
                            devices = { page = "device" },
                            openEntry = { id ->
                                selected = id
                                state.entries.firstOrNull { it.optString("id") == id }?.let { page = workspaceDestination(it.optString("type")) }
                            },
                        )
                    page == "relay" -> RelaySettingsScreen(vault, t)
                    page == "webdav" -> WebDavScreen(vault, state, t)
                    else ->
                        key(page) {
                            EntryCollection(
                                page,
                                destinations[page] ?: secondary[page].orEmpty(),
                                state,
                                vault,
                                t,
                                open = { selected = it.optString("id") },
                                edit = {
                                    editingRestored = false
                                    editing = JSONObject(it.toString())
                                },
                                delete = { deleting = it },
                                manageCategories = { settingsStart = "general"; page = "settings" },
                                ui = collectionStates.getOrPut(page) { CollectionUiState() },
                                operationScope = scope,
                                openNavigation = { scope.launch { drawer.open() } },
                                openHealth = { settingsStart = "health"; page = "settings" },
                            )
                        }
                }
            }
        }
    }
    }
    current?.let { item -> EntryMenu(detailMenu, { detailMenu = false }, item, vault, t, { editingRestored = false; editing = JSONObject(item.toString()) }, { deleting = item }) }
    editing?.let {
        EntryEditor(it, vault, t, restoredDraft = editingRestored, openGenerator = editingGenerator) {
            editing = null
            editingRestored = false
            editingGenerator = false
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
                            val permanent = target.optBoolean("isDeleted")
                            val ok = if (permanent) vault.remove(target) else vault.trash(target)
                            if (ok) {
                                deleting = null
                                if (selected == target.optString("id")) selected = null
                                // Moving to Trash can be undone right away; permanent deletion cannot.
                                if (!permanent) {
                                    val result = snackbar.showSnackbar(
                                        message = t("已移到回收站", "Moved to Trash"),
                                        actionLabel = t("撤销", "Undo"),
                                        duration = SnackbarDuration.Short,
                                    )
                                    if (result == SnackbarResult.ActionPerformed) {
                                        val id = target.optString("id")
                                        vault.state.value.entries.firstOrNull { it.optString("id") == id && it.optBoolean("isDeleted") }
                                            ?.let { if (!vault.trash(it)) snackbar.showSnackbar(t("无法恢复，请在回收站中操作", "Could not restore; use Trash")) }
                                    }
                                }
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
