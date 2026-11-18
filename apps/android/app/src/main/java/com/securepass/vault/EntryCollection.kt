package com.securepass.vault

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridItemSpan
import androidx.compose.foundation.lazy.staggeredgrid.items as gridItems
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject

internal fun entryTags(item: JSONObject): List<String> =
    item
        .optJSONArray("tags")
        ?.let { array ->
            (0 until array.length()).map { array.optString(it) }.filter { it.isNotBlank() }
        }
        .orEmpty()

internal fun noteDate(item: JSONObject): String =
    runCatching {
            java.text
                .SimpleDateFormat("MM/dd HH:mm", java.util.Locale.getDefault())
                .format(java.util.Date(Instant.parse(item.optString("updatedAt")).toEpochMilli()))
        }
        .getOrDefault("")

internal class CollectionUiState {
    val tools = CollectionToolsState()
    val search = mutableStateOf("")
    val category = mutableStateOf("")
    val tag = mutableStateOf("")
    val favorites = mutableStateOf(false)
    val kind = mutableStateOf("")
    val selecting = mutableStateOf(false)
    val selectedIds = mutableStateOf(setOf<String>())
    val grid = mutableStateOf(true)
    val list = androidx.compose.foundation.lazy.LazyListState()
    val masonry = androidx.compose.foundation.lazy.staggeredgrid.LazyStaggeredGridState()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EntryCollection(
    page: String, title: String, state: VaultState, vault: VaultRepository,
    t: (String, String) -> String, open: (JSONObject) -> Unit, edit: (JSONObject) -> Unit,
    delete: (JSONObject) -> Unit, manageCategories: () -> Unit, ui: CollectionUiState,
    operationScope: kotlinx.coroutines.CoroutineScope, openNavigation: (() -> Unit)? = null,
    openHealth: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val notes = page == "secureNote"
    var search by ui.search
    var category by ui.category
    var kind by ui.kind
    var favorites by ui.favorites
    var tag by ui.tag
    var grid by ui.grid
    var sortSheet by remember { mutableStateOf(false) }
    var categoriesSheet by remember { mutableStateOf(false) }
    var toolsSheet by remember { mutableStateOf(false) }
    var categoryName by remember { mutableStateOf("") }
    var addingCategory by remember { mutableStateOf(false) }
    var categoryBusy by remember { mutableStateOf(false) }
    var categoryToRemove by remember { mutableStateOf<String?>(null) }
    var emptyingTrash by remember { mutableStateOf(false) }
    var audit by remember { mutableStateOf(emptyList<JSONObject>()) }
    val relayState by vault.relay.state.collectAsState()
    val offline = relayOffline(relayState)
    DisposableEffect(page) { onDispose { ui.selectedIds.value = emptySet(); ui.selecting.value = false } }
    LaunchedEffect(ui.selecting.value) { if (ui.selecting.value) toolsSheet = false }
    LaunchedEffect(state.entries) {
        audit = runCatching { vault.audit().objects() }.getOrDefault(emptyList())
    }
    val findings = audit.associateBy { it.optString("id") }
    val source = state.entries.filter { matchesWorkspaceDestination(it, page) }
    val categories = (state.settings.optJSONArray("noteCategories")?.let { a -> (0 until a.length()).map { a.optString(it) } }.orEmpty() + source.map { it.optString("category") })
        .filter { it.isNotBlank() }.distinct().sorted()
    val sort = state.settings.optJSONObject("collectionSort")?.optString(page, "updatedDesc") ?: "updatedDesc"
    val filtered = source.filter { item ->
        (kind.isEmpty() || (if (kind == "issue") item.optString("id") in findings else item.optString("type") == kind)) &&
        (category.isEmpty() || item.optString("category") == category) &&
        (!favorites || item.optBoolean("isFavorite")) &&
        (tag.isEmpty() || tag in entryTags(item)) &&
        (search.isBlank() || listOf("title", "username", "email", "url", "category", "note").any { item.optString(it).contains(search, true) } ||
            entryTags(item).any { it.contains(search, true) } || item.optJSONObject("device")?.let { listOf("host", "username").any { key -> it.optString(key).contains(search, true) } } == true)
    }.sortedWith(compareByDescending<JSONObject> { it.optBoolean("isPinned") }.thenComparator { a, b ->
        when (sort) {
            "titleAsc" -> a.optString("title").compareTo(b.optString("title"), true)
            "titleDesc" -> b.optString("title").compareTo(a.optString("title"), true)
            "updatedAsc" -> a.optString("updatedAt").compareTo(b.optString("updatedAt"))
            else -> b.optString("updatedAt").compareTo(a.optString("updatedAt"))
        }
    })
    fun clearSelection() { ui.selectedIds.value = emptySet() }
    fun select(item: JSONObject) {
        if (!vault.canEdit(item)) return
        ui.selecting.value = true
        val id = item.optString("id")
        ui.selectedIds.value = if (id in ui.selectedIds.value) ui.selectedIds.value - id else ui.selectedIds.value + id
    }
    fun openItem(item: JSONObject) { if (ui.selecting.value) select(item) else open(item) }
    val headerGutter = if (notes && grid) 10.dp else 0.dp
    val header: @Composable () -> Unit = {
        Column {
            if (ui.selecting.value) {
                Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { ui.selecting.value = false; clearSelection() }) { Icon(Icons.Outlined.Close, t("取消选择", "Cancel selection")) }
                    Text(t("已选择 ${ui.selectedIds.value.size} 项", "${ui.selectedIds.value.size} selected"), Modifier.weight(1f))
                    IconButton(onClick = { ui.selectedIds.value = filtered.filter { vault.canEdit(it) }.map { it.optString("id") }.toSet() }) { Icon(Icons.Outlined.DoneAll, t("全选", "Select all")) }
                    IconButton(enabled = ui.selectedIds.value.isNotEmpty(), onClick = { ui.tools.operation.value = "favorite" }) { Icon(Icons.Outlined.StarOutline, t("收藏所选", "Favorite selected")) }
                    IconButton(enabled = ui.selectedIds.value.isNotEmpty(), onClick = { ui.tools.operation.value = "category" }) { Icon(Icons.Outlined.FolderOpen, t("移动到分类", "Move to category")) }
                    IconButton(enabled = ui.selectedIds.value.isNotEmpty(), onClick = { ui.tools.operation.value = "delete" }) { Icon(Icons.Outlined.DeleteOutline, t("移到回收站", "Move to Trash")) }
                }
            } else {
                Surface(modifier = Modifier.fillMaxWidth().padding(start = 14.dp - headerGutter, end = 14.dp - headerGutter, top = 4.dp, bottom = 6.dp), shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
                    Row(Modifier.height(50.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { openNavigation?.invoke() }) { Icon(Icons.Outlined.MoreHoriz, t("打开导航", "Open navigation"), Modifier.size(20.dp)) }
                        androidx.compose.foundation.text.BasicTextField(
                            value = search, onValueChange = { search = it; clearSelection() }, singleLine = true,
                            modifier = Modifier.weight(1f), textStyle = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurface),
                            cursorBrush = androidx.compose.ui.graphics.SolidColor(MaterialTheme.colorScheme.primary),
                            decorationBox = { inner -> Box { if (search.isEmpty()) Text(when (page) {
                                "secureNote" -> t("搜索笔记", "Search notes")
                                "password" -> t("搜索账号", "Search accounts")
                                "totp" -> t("搜索验证码", "Search codes")
                                "wallets" -> t("搜索钱包", "Search wallets")
                                else -> t("搜索$title", "Search $title")
                            }, maxLines = 1, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium); inner() } },
                        )
                        if (search.isNotEmpty()) IconButton(onClick = { search = ""; clearSelection() }) { Icon(Icons.Outlined.Close, t("清空搜索", "Clear search"), Modifier.size(20.dp)) }
                        IconButton(onClick = vault::lock) { Icon(Icons.Outlined.Lock, t("锁定", "Lock"), Modifier.size(20.dp)) }
                    }
                }

            }
            Row(Modifier.fillMaxWidth().padding(start = 18.dp - headerGutter, end = 6.dp).heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(title, Modifier.weight(1f), style = MaterialTheme.typography.headlineMedium)
                if (notes) {
                    IconButton(onClick = { grid = !grid }) { Icon(if (grid) Icons.Outlined.ViewAgenda else Icons.Outlined.GridView, if (grid) t("切换列表", "List view") else t("切换网格", "Grid view"), Modifier.size(20.dp)) }
                    IconButton(onClick = { sortSheet = true }) { Icon(Icons.Outlined.SwapVert, t("排序", "Sort"), Modifier.size(20.dp)) }
                } else {
                    Box {
                        IconButton(onClick = { toolsSheet = true }) { Icon(Icons.Outlined.MoreHoriz, t("资料工具", "Collection tools"), Modifier.size(20.dp)) }
                    }
                }
            }
            if (page != "favorites" && page != "trash") Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(start = 14.dp - headerGutter, end = 14.dp - headerGutter, bottom = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                @Composable fun chip(label: String, selected: Boolean, action: () -> Unit) {
                    FilterChip(selected = selected, modifier = Modifier.height(32.dp), onClick = { action(); clearSelection() }, label = { Text(label, style = MaterialTheme.typography.labelMedium) },
                        shape = RoundedCornerShape(8.dp), border = BorderStroke(1.dp, if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.outlineVariant),
                        colors = FilterChipDefaults.filterChipColors(containerColor = MaterialTheme.colorScheme.surface, selectedContainerColor = MaterialTheme.colorScheme.primaryContainer, selectedLabelColor = MaterialTheme.colorScheme.primary),
                    )
                }
                if (notes) {
                    chip(t("全部 ${source.size}", "All ${source.size}"), category.isEmpty()) { category = "" }
                    categories.forEach { name -> chip("$name ${source.count { it.optString("category") == name }}", category == name) { category = name } }
                    chip(t("管理", "Manage"), false) { categoriesSheet = true }
                } else if (page == "wallets") {
                    listOf("" to t("全部", "All"), "creditCard" to t("银行卡", "Cards"), "identity" to t("证件", "Identities"), "crypto" to t("加密货币", "Crypto")).forEach { (value, label) -> chip(label, kind == value) { kind = value } }
                } else {
                    chip(t("全部", "All"), !favorites && kind.isEmpty() && category.isEmpty()) { favorites = false; kind = ""; category = "" }
                    chip(t("收藏", "Favorites"), favorites) { favorites = !favorites; kind = ""; category = "" }
                    if (page == "password") {
                        chip(t("需要处理", "Needs attention"), kind == "issue") { kind = if (kind == "issue") "" else "issue"; favorites = false; category = "" }
                        categories.forEach { name -> chip(name, category == name) { category = name; kind = ""; favorites = false } }
                    }
                }
            }
            if (offline && page != "trash") OfflineBanner(t, Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, bottom = 12.dp))
            if (page == "totp") Text(t("点按复制当前验证码 · 时间以手机系统时钟为准", "Tap to copy the current code · Uses your device clock"),
                Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (page == "password" && audit.isNotEmpty() && search.isBlank() && !favorites && kind.isEmpty()) Surface(
                onClick = openHealth, modifier = Modifier.fillMaxWidth().padding(start = 10.dp, end = 10.dp, bottom = 12.dp), shape = RoundedCornerShape(14.dp), color = Color(0xFFB86A12).copy(alpha = .10f),
            ) { Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Outlined.GppMaybe, null, tint = Color(0xFFB86A12), modifier = Modifier.size(22.dp))
                Column { Text(t("${audit.size} 个账号需要处理", "${audit.size} accounts need attention"), style = MaterialTheme.typography.titleMedium)
                    Text(t("弱密码、重复使用或已过期 · 查看密码健康", "Weak, reused or expired passwords · View password health"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            } }
            if (page == "trash" && source.isNotEmpty()) Surface(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp), color = MaterialTheme.colorScheme.primaryContainer, shape = RoundedCornerShape(14.dp)) {
                Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) { Icon(Icons.Outlined.Info, null, tint = MaterialTheme.colorScheme.primary); Column {
                    Text(t("已删除的项目", "Deleted items"), style = MaterialTheme.typography.titleMedium)
                    Text(t("恢复后回到原位置并保留全部字段与历史。", "Restore to the original location with all fields and history."), style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { emptyingTrash = true }, enabled = !state.busy, contentPadding = PaddingValues(0.dp)) {
                        Text(t("清空回收站…", "Empty Trash…"), color = MaterialTheme.colorScheme.error)
                    }
                } }
            }
        }
    }
    val empty: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().padding(horizontal = 28.dp, vertical = 50.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Icon(if (search.isNotBlank()) Icons.Outlined.Search else if (notes) Icons.Outlined.Description else if (page == "favorites") Icons.Outlined.StarOutline else Icons.Outlined.Inbox, null, Modifier.size(42.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .55f))
            Text(when {
                search.isNotBlank() -> t("没有找到“$search”", "No results for “$search”")
                notes -> t("这个分类还没有笔记", "No notes in this category")
                page == "favorites" -> t("还没有收藏", "No favorites yet")
                page == "trash" -> t("回收站是空的", "Trash is empty")
                page == "totp" -> t("还没有验证码", "No codes yet")
                else -> t("这里还没有内容", "Nothing here yet")
            }, style = MaterialTheme.typography.titleMedium)
            Text(when {
                search.isNotBlank() -> t("试试用户名、网站、标签或分类。", "Try a username, website, tag or category.")
                notes -> t("删除分类只会清空归类，不会删除笔记。", "Removing a category keeps its notes.")
                page == "favorites" -> t("在详情页点星标即可收藏。", "Tap the star in a detail to add a favorite.")
                page == "totp" -> t("扫描网站提供的二维码，或手动输入密钥。", "Scan a QR code or enter a setup key.")
                page == "trash" -> t("删除的项目会显示在这里。", "Deleted items appear here.")
                else -> t("点“新建”添加第一项。", "Tap New to add the first item.")
            }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (search.isNotEmpty()) OutlinedButton(onClick = { search = "" }) { Text(t("清除搜索", "Clear search")) }
        }
    }
    if (notes && grid) {
        LazyVerticalStaggeredGrid(columns = StaggeredGridCells.Fixed(if (LocalDensity.current.fontScale > 1.2f) 1 else 2), state = ui.masonry,
            modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 10.dp, end = 10.dp, bottom = 100.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalItemSpacing = 8.dp) {
            item(key = "controls", span = StaggeredGridItemSpan.FullLine) { header() }
            if (filtered.isEmpty()) item(key = "empty", span = StaggeredGridItemSpan.FullLine) { empty() }
            gridItems(filtered, key = { it.getString("id") }) { item ->
                NoteCard(item, vault, t, { openItem(item) }, { edit(item) }, { delete(item) }, if (ui.selecting.value) item.optString("id") in ui.selectedIds.value else null)
            }
        }
    } else LazyColumn(state = ui.list, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 100.dp)) {
        item(key = "controls") { header() }
        if (filtered.isEmpty()) item(key = "empty") { empty() }
        itemsIndexed(filtered, key = { _, item -> item.getString("id") }) { index, item ->
            Surface(modifier = Modifier.padding(horizontal = 10.dp), color = MaterialTheme.colorScheme.surface,
                shape = RoundedCornerShape(topStart = if (index == 0) 16.dp else 0.dp, topEnd = if (index == 0) 16.dp else 0.dp, bottomStart = if (index == filtered.lastIndex) 16.dp else 0.dp, bottomEnd = if (index == filtered.lastIndex) 16.dp else 0.dp)) {
                Column {
                    CredentialCard(item, vault, t, { openItem(item) }, { edit(item) }, { delete(item) }, if (ui.selecting.value) item.optString("id") in ui.selectedIds.value else null, { select(item) }, findings[item.optString("id")])
                    if (index != filtered.lastIndex) HorizontalDivider(Modifier.padding(start = 60.dp), thickness = .5.dp, color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .45f))
                }
            }
        }
    }
    CollectionTools(page, ui, filtered, state, vault, t, manageCategories, operationScope, showToolbar = false)
    if (toolsSheet) ModalBottomSheet(onDismissRequest = { toolsSheet = false }) {
        Text(t("资料工具", "Collection tools"), Modifier.padding(horizontal = 20.dp), style = MaterialTheme.typography.titleLarge)
        TextButton(onClick = { toolsSheet = false; sortSheet = true }) { Text(t("排序", "Sort")) }
        CollectionTools(page, ui, filtered, state, vault, t, { toolsSheet = false; manageCategories() }, operationScope)
        Spacer(Modifier.height(24.dp))
    }
    if (sortSheet) ModalBottomSheet(onDismissRequest = { sortSheet = false }) {
        Text(t("排序", "Sort"), Modifier.padding(horizontal = 20.dp, vertical = 8.dp), style = MaterialTheme.typography.titleLarge)
        listOf("updatedDesc" to t("最近修改", "Recently updated"), "updatedAsc" to t("最早修改", "Oldest updated"), "titleAsc" to t("标题升序", "Title A–Z"), "titleDesc" to t("标题降序", "Title Z–A")).forEach { (value, label) ->
            ListItem(headlineContent = { Text(label) }, trailingContent = { if (sort == value) Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.primary) }, modifier = Modifier.clickable {
                scope.launch { val sorts = JSONObject(state.settings.optJSONObject("collectionSort")?.toString() ?: "{}").put(page, value); if (vault.mutate("settings", JSONObject().put("settings", JSONObject().put("collectionSort", sorts)))) sortSheet = false }
            })
        }
        if (notes) TextButton(onClick = { sortSheet = false; toolsSheet = true }, modifier = Modifier.padding(horizontal = 12.dp)) { Text(t("资料工具", "Collection tools")) }
        Spacer(Modifier.height(20.dp))
    }
    if (categoriesSheet) ModalBottomSheet(sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), onDismissRequest = { if (!categoryBusy) categoriesSheet = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(t("笔记分类", "Note categories"), style = MaterialTheme.typography.titleLarge)
            Text(t("删除分类只会清空归类，不会删除笔记。", "Removing a category keeps its notes."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainerLow) {
                Column {
                    categories.forEachIndexed { index, name ->
                        Row(Modifier.fillMaxWidth().heightIn(min = 62.dp).padding(start = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.FolderOpen, null, Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                Text(name, style = MaterialTheme.typography.bodyMedium)
                                Text(t("${source.count { it.optString("category") == name }} 篇", "${source.count { it.optString("category") == name }} notes"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            IconButton(enabled = !categoryBusy, onClick = { categoryToRemove = name }) { Icon(Icons.Outlined.DeleteOutline, t("删除分类", "Remove category"), Modifier.size(18.dp)) }
                        }
                        if (index != categories.lastIndex) HorizontalDivider(Modifier.padding(start = 46.dp), thickness = .5.dp, color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .45f))
                    }
                }
            }
            if (addingCategory) Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(categoryName, { categoryName = it }, label = { Text(t("新分类", "New category")) }, singleLine = true, modifier = Modifier.weight(1f), enabled = !categoryBusy)
                TextButton(enabled = !categoryBusy && categoryName.isNotBlank(), onClick = { scope.launch { categoryBusy = true; if (vault.mutate("category-add", JSONObject().put("name", categoryName.trim()))) { categoryName = ""; addingCategory = false }; categoryBusy = false } }) { Text(t("添加", "Add")) }
            } else FilledTonalButton(onClick = { addingCategory = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.Add, null, Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(t("新建分类", "New category"))
            }
            Spacer(Modifier.height(24.dp))
        }
    }
    if (emptyingTrash) {
        // Items in a shared vault cannot be deleted permanently from here; they stay in Trash.
        val removable = state.entries.filter { it.optBoolean("isDeleted") && vault.canEdit(it) && it.optString("sharedVaultId").isEmpty() }
        val kept = state.entries.count { it.optBoolean("isDeleted") } - removable.size
        AlertDialog(
            onDismissRequest = { if (!state.busy) emptyingTrash = false },
            title = { Text(t("清空回收站？", "Empty Trash?")) },
            text = { Text(t("将永久删除 ${removable.size} 个项目，无法恢复。", "Permanently delete ${removable.size} items. This cannot be undone.") +
                if (kept > 0) t("共享资料库中的 $kept 个项目会保留在回收站。", " $kept shared items stay in Trash.") else "") },
            confirmButton = {
                TextButton(enabled = !state.busy && removable.isNotEmpty(), onClick = {
                    operationScope.launch { for (item in removable) vault.remove(item); emptyingTrash = false }
                }) { Text(t("永久删除", "Delete permanently"), color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(enabled = !state.busy, onClick = { emptyingTrash = false }) { Text(t("取消", "Cancel")) } },
        )
    }
    categoryToRemove?.let { name -> AlertDialog(onDismissRequest = { if (!categoryBusy) categoryToRemove = null }, title = { Text(t("删除分类“$name”？", "Remove “$name”?")) }, text = { Text(t("笔记会保留，只清空归类。", "Notes are kept; only their category is cleared.")) },
        confirmButton = { TextButton(enabled = !categoryBusy, onClick = { scope.launch { categoryBusy = true; if (vault.mutate("category-remove", JSONObject().put("name", name).put("time", Instant.now().toString()))) { if (category == name) category = ""; categoryToRemove = null }; categoryBusy = false } }) { Text(t("删除分类", "Remove category")) } }, dismissButton = { TextButton(enabled = !categoryBusy, onClick = { categoryToRemove = null }) { Text(t("取消", "Cancel")) } }) }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CredentialCard(
    item: JSONObject, vault: VaultRepository, t: (String, String) -> String,
    open: () -> Unit, edit: () -> Unit, delete: () -> Unit, selection: Boolean? = null,
    longSelect: () -> Unit = {}, finding: JSONObject? = null,
) {
    val type = item.optString("type")
    var code by remember(item.optString("id")) { mutableStateOf("") }
    var remaining by remember { mutableIntStateOf(0) }
    val period = item.optInt("period", 30).coerceAtLeast(1)
    var menu by remember { mutableStateOf(false) }
    val hasCode = type == "totp" && item.optString("secret").isNotBlank() && !item.optBoolean("isDeleted")
    LaunchedEffect(item.toString()) {
        if (hasCode) while (true) {
            remaining = period - (System.currentTimeMillis() / 1000 % period).toInt()
            code = runCatching { vault.command("totp", JSONObject().put("secret", item.optString("secret")).put("period", period).put("time", System.currentTimeMillis() / 1000)).optString("code") }.getOrDefault("")
            delay(1000)
        }
    }
    val sub = when (type) {
        "secureNote" -> item.optString("note").lineSequence().firstOrNull { it.isNotBlank() }.orEmpty()
        "crypto" -> item.optString("address").let { if (it.length > 22) it.take(10) + "…" + it.takeLast(6) else it }
        "creditCard" -> item.optJSONObject("card")?.let { card -> listOf(card.optString("bank").ifBlank { card.optString("brand") }, card.optString("number").takeLast(4).let { if (it.isNotBlank()) "•••• $it" else "" }).filter { it.isNotBlank() }.joinToString(" · ") }.orEmpty()
        "identity" -> item.optJSONObject("identity")?.let { it.optString("name").ifBlank { it.optString("fullName") }.ifBlank { listOf(it.optString("lastName"), it.optString("firstName")).filter { part -> part.isNotBlank() }.joinToString(" ") } }.orEmpty()
        "device" -> item.optJSONObject("device")?.let { listOf(it.optString("username"), it.optString("host")).filter { it.isNotBlank() }.joinToString("@") }.orEmpty()
        else -> item.optString("username").ifBlank { item.optString("url") }
    }
    Row(Modifier.fillMaxWidth().combinedClickable(onClick = { if (hasCode && selection == null) { if (code.isNotBlank()) vault.copy(code) } else open() }, onLongClick = { if (item.optBoolean("isDeleted") || type == "secureNote") menu = true else longSelect() }).padding(start = 14.dp, end = 4.dp, top = 6.dp, bottom = 6.dp).heightIn(min = 50.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        if (selection != null) {
            Surface(shape = RoundedCornerShape(10.dp), color = if (selection) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primaryContainer, modifier = Modifier.size(38.dp)) {
                Box(contentAlignment = Alignment.Center) { if (selection) Icon(Icons.Outlined.Check, null, tint = MaterialTheme.colorScheme.onPrimary) }
            }
        } else if (hasCode) {
            CircularProgressIndicator(progress = { remaining.toFloat() / period }, modifier = Modifier.size(30.dp), strokeWidth = 3.dp, trackColor = MaterialTheme.colorScheme.outlineVariant)
        } else {
            val icon = when (type) { "secureNote" -> Icons.Outlined.Description; "creditCard" -> Icons.Outlined.CreditCard; "identity" -> Icons.Outlined.Badge; "crypto" -> Icons.Outlined.CurrencyBitcoin; "device" -> Icons.Outlined.Dns; "totp" -> Icons.Outlined.Timer; else -> null }
            val tint = if (icon != null) MaterialTheme.colorScheme.primaryContainer else accountTileColor(item.optString("title"))
            Surface(shape = RoundedCornerShape(11.dp), color = tint, modifier = Modifier.size(38.dp)) {
                Box(contentAlignment = Alignment.Center) { if (icon != null) Icon(icon, null, Modifier.size(22.dp), tint = MaterialTheme.colorScheme.primary) else Text(item.optString("title").take(1).uppercase(), color = Color.White, style = MaterialTheme.typography.titleMedium) }
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (item.optBoolean("isPinned")) Icon(Icons.Outlined.PushPin, t("已置顶", "Pinned"), Modifier.size(12.dp))
                Text(item.optString("title"), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                if (item.optBoolean("isFavorite")) Text("★", color = Color(0xFFB86A12), style = MaterialTheme.typography.labelSmall)
                if (finding != null) Surface(shape = RoundedCornerShape(6.dp), color = Color(0xFFB86A12).copy(alpha = .1f)) { Text(when { finding.optBoolean("weak") -> t("弱密码", "Weak"); finding.optBoolean("reused") -> t("重复", "Reused"); else -> t("过期", "Expired") }, Modifier.padding(horizontal = 4.dp, vertical = 1.dp), style = MaterialTheme.typography.labelSmall, color = Color(0xFFB86A12)) }
            }
            if (sub.isNotBlank()) Text(sub.replace(Regex("[\\r\\n]+"), " "), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!vault.canEdit(item)) Text(t("只读", "Read only"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (selection == null && !item.optBoolean("isDeleted")) {
            if (hasCode) {
                Text(code.chunked(3).joinToString(" "), color = MaterialTheme.colorScheme.primary, fontFamily = FontFamily.Monospace, fontSize = 18.sp)
                IconButton(onClick = open) { Icon(Icons.Outlined.ChevronRight, t("详情", "Details"), Modifier.size(18.dp)) }
            } else if (type == "password") IconButton(enabled = item.optString("password").isNotBlank(), onClick = { vault.copy(item.optString("password")) }) { Icon(Icons.Outlined.ContentCopy, t("复制密码", "Copy password"), Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
    }
    EntryMenu(menu, { menu = false }, item, vault, t, edit, delete)
}

private fun accountTileColor(title: String): Color = when (title.take(1).uppercase()) {
    "G" -> Color(0xFF24292F); "A" -> Color(0xFF555A64); "F" -> Color(0xFF9360EE)
    else -> Color(0xFF3265DB)
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteCard(item: JSONObject, vault: VaultRepository, t: (String, String) -> String, open: () -> Unit, edit: () -> Unit, delete: () -> Unit, selection: Boolean? = null) {
    var menu by remember { mutableStateOf(false) }
    Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, if (selection == true) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant.copy(alpha = .45f)),
        modifier = Modifier.fillMaxWidth().combinedClickable(onClick = open, onLongClick = { if (selection != null) open() else menu = true }, onLongClickLabel = t("笔记操作", "Note actions"))) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (selection != null) Checkbox(selection, { open() }, enabled = vault.canEdit(item), modifier = Modifier.size(24.dp))
                if (item.optBoolean("isPinned")) Icon(Icons.Outlined.PushPin, t("已置顶", "Pinned"), Modifier.size(14.dp))
                Text(item.optString("title").ifEmpty { t("未命名笔记", "Untitled note") }, style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            val preview = item.optString("note").replace(Regex("(?m)^\\s{0,3}(#+\\s*|[-*+]\\s+)"), "").replace("**", "").trim()
            if (preview.isNotBlank()) Text(preview, color = MaterialTheme.colorScheme.onSurfaceVariant, fontSize = 13.sp, lineHeight = 19.sp, maxLines = 5, overflow = TextOverflow.Ellipsis)
            Text(listOf(noteDate(item), item.optString("category"), if (item.optBoolean("isFavorite")) "★" else "").filter { it.isNotBlank() }.joinToString(" · "), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
    EntryMenu(menu, { menu = false }, item, vault, t, edit, delete)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun EntryMenu(expanded: Boolean, dismiss: () -> Unit, item: JSONObject, vault: VaultRepository, t: (String, String) -> String, edit: () -> Unit, delete: () -> Unit) {
    val scope = rememberCoroutineScope()
    val editable = vault.canEdit(item)
    var history by remember(item.optString("id")) { mutableStateOf(false) }
    var moving by remember(item.optString("id")) { mutableStateOf(false) }
    val state by vault.state.collectAsState()
    if (history) HistoryDialog(vault, item.optString("id"), t) { history = false }
    if (expanded) ModalBottomSheet(onDismissRequest = dismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            Text(item.optString("title"), Modifier.padding(horizontal = 20.dp, vertical = 8.dp), style = MaterialTheme.typography.titleLarge)
            @Composable fun action(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, enabled: Boolean = true, danger: Boolean = false, click: () -> Unit) {
                ListItem(headlineContent = { Text(label, color = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface) }, leadingContent = { Icon(icon, null, tint = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant) }, modifier = Modifier.clickable(enabled = enabled, onClick = click), colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface))
            }
            if (!item.optBoolean("isDeleted")) {
                if (editable && item.optString("type") != "device") action(t("编辑", "Edit"), Icons.Outlined.Edit) { dismiss(); edit() }
                listOf("isPinned" to (if (item.optBoolean("isPinned")) t("取消置顶", "Unpin") else t("置顶", "Pin")), "isFavorite" to (if (item.optBoolean("isFavorite")) t("取消收藏", "Unfavorite") else t("收藏", "Favorite"))).forEach { (field, label) ->
                    action(label, if (field == "isPinned") Icons.Outlined.PushPin else Icons.Outlined.StarOutline, editable) { dismiss(); scope.launch { vault.save(JSONObject(item.toString()).put(field, !item.optBoolean(field))) } }
                }
                if (editable) action(t("移动到分类", "Move to category"), Icons.Outlined.FolderOpen) { dismiss(); moving = true }
                action(t("版本历史", "Version history"), Icons.Outlined.History) { dismiss(); history = true }
                if (item.optString("type") == "totp") action(t("导出 otpauth 链接", "Export otpauth link"), Icons.Outlined.QrCode) { dismiss(); vault.copy(totpSetupUri(item)) }
            } else action(t("恢复", "Restore"), Icons.Outlined.Restore, editable) { dismiss(); scope.launch { vault.trash(item) } }
            HorizontalDivider(Modifier.padding(horizontal = 20.dp))
            action(if (item.optBoolean("isDeleted")) t("永久删除…", "Delete permanently…") else t("移到回收站", "Move to Trash"), Icons.Outlined.DeleteOutline, editable && !(item.optBoolean("isDeleted") && item.optString("sharedVaultId").isNotEmpty()), true) { dismiss(); delete() }
            if (!editable) Text(t("此共享资料为只读", "This shared entry is read only"), Modifier.padding(20.dp), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(20.dp))
        }
    }
    if (moving) ModalBottomSheet(onDismissRequest = { moving = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            Text(t("移动到分类", "Move to category"), Modifier.padding(20.dp), style = MaterialTheme.typography.titleLarge)
            val categories = (state.settings.optJSONArray("noteCategories")?.let { a -> (0 until a.length()).map { a.optString(it) } }.orEmpty() + state.entries.map { it.optString("category") }).filter { it.isNotBlank() }.distinct().sorted()
            (listOf("") + categories).forEach { name -> ListItem(headlineContent = { Text(name.ifBlank { t("未分类", "Unfiled") }) }, modifier = Modifier.clickable { scope.launch { if (vault.canEdit(item) && vault.save(JSONObject(item.toString()).put("category", name))) moving = false } }) }
            Spacer(Modifier.height(20.dp))
        }
    }
}
