package com.securepass.vault

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.staggeredgrid.LazyVerticalStaggeredGrid
import androidx.compose.foundation.lazy.staggeredgrid.StaggeredGridCells
import androidx.compose.foundation.lazy.staggeredgrid.items as gridItems
import androidx.compose.foundation.rememberScrollState
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
    val vaultFilter = mutableStateOf("*")
    val selecting = mutableStateOf(false)
    val selectedIds = mutableStateOf(setOf<String>())
    val grid = mutableStateOf(true)
    val list = androidx.compose.foundation.lazy.LazyListState()
    val masonry = androidx.compose.foundation.lazy.staggeredgrid.LazyStaggeredGridState()
}

@Composable
internal fun EntryCollection(
    page: String,
    title: String,
    state: VaultState,
    vault: VaultRepository,
    t: (String, String) -> String,
    open: (JSONObject) -> Unit,
    edit: (JSONObject) -> Unit,
    delete: (JSONObject) -> Unit,
    manageCategories: () -> Unit,
    ui: CollectionUiState,
    operationScope: kotlinx.coroutines.CoroutineScope,
) {
    DisposableEffect(page) {
        onDispose {
            ui.selectedIds.value = emptySet()
            ui.selecting.value = false
        }
    }
    val notes = page == "secureNote"
    var search by ui.search
    var category by ui.category
    var tag by ui.tag
    var favorites by ui.favorites
    val scope = rememberCoroutineScope()
    val sort =
        state.settings.optJSONObject("collectionSort")?.optString(page, "updatedDesc")
            ?: "updatedDesc"
    fun setSort(value: String) {
        scope.launch {
            val sorts =
                JSONObject(state.settings.optJSONObject("collectionSort")?.toString() ?: "{}")
            sorts.put(page, value)
            vault.mutate(
                "settings",
                JSONObject().put("settings", JSONObject().put("collectionSort", sorts)),
            )
        }
    }
    fun openItem(item: JSONObject) {
        if (ui.selecting.value) {
            if (vault.canEdit(item)) {
                val id = item.optString("id")
                ui.selectedIds.value =
                    if (id in ui.selectedIds.value) ui.selectedIds.value - id
                    else ui.selectedIds.value + id
            }
        } else open(item)
    }
    var sortMenu by remember { mutableStateOf(false) }
    var folderMenu by remember { mutableStateOf(false) }
    var grid by ui.grid
    val source =
        state.entries.filter {
            if (page == "trash") it.optBoolean("isDeleted")
            else !it.optBoolean("isDeleted") && it.optString("type") == page
        }
    val configured =
        if (notes)
            state.settings
                .optJSONArray("noteCategories")
                ?.let { a -> (0 until a.length()).map { a.optString(it) } }
                .orEmpty()
        else emptyList()
    val categories =
        (source.map { it.optString("category") } + configured)
            .filter { it.isNotBlank() }
            .distinct()
            .sorted()
    val tags = source.flatMap(::entryTags).distinct().sorted()
    val filtered =
        source
            .filter { item ->
                (ui.vaultFilter.value == "*" ||
                    item.optString("sharedVaultId") == ui.vaultFilter.value) &&
                    (category.isEmpty() || item.optString("category") == category) &&
                    (tag.isEmpty() || tag in entryTags(item)) &&
                    (!favorites || item.optBoolean("isFavorite")) &&
                    (search.isBlank() ||
                        listOf("title", "username", "email", "url", "category", "note").any {
                            item.optString(it).contains(search, true)
                        } ||
                        entryTags(item).any { it.contains(search, true) })
            }
            .sortedWith(
                compareByDescending<JSONObject> { it.optBoolean("isPinned") }
                    .thenComparator { a, b ->
                        when (sort) {
                            "titleAsc" ->
                                a.optString("title")
                                    .compareTo(b.optString("title"), ignoreCase = true)
                            "titleDesc" ->
                                b.optString("title")
                                    .compareTo(a.optString("title"), ignoreCase = true)
                            "updatedAsc" ->
                                a.optString("updatedAt").compareTo(b.optString("updatedAt"))
                            else -> b.optString("updatedAt").compareTo(a.optString("updatedAt"))
                        }
                    }
            )
    val compact =
        WindowInsets.ime.getBottom(LocalDensity.current) > 0 ||
            LocalConfiguration.current.screenHeightDp < 500
    val inlineNoteTools = notes && !compact && !ui.selecting.value && state.sharedVaults.isEmpty()
    val header: @Composable () -> Unit = {
        Column {
            if (!compact && !notes)
                Column(
                    Modifier.padding(horizontal = 20.dp).padding(top = 16.dp, bottom = 18.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        if (notes) t("笔记", "Notes") else title,
                        style = MaterialTheme.typography.headlineMedium,
                    )
                    Text(
                        when (page) {
                            "password" -> t("登录信息，随时取用。", "Your logins, ready when you need them.")
                            "totp" -> t("验证码就在手边。", "Your verification codes, at a glance.")
                            "crypto" ->
                                t("集中管理钱包与恢复信息。", "Wallets and recovery information, together.")
                            "secureNote" ->
                                t("记下想法，也收好重要的事。", "A place for ideas and things that matter.")
                            else -> t("删除的资料可以在这里恢复。", "Restore deleted entries here.")
                        },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            OutlinedTextField(
                value = search,
                onValueChange = {
                    search = it
                    ui.selectedIds.value = emptySet()
                },
                singleLine = true,
                placeholder = {
                    Text(
                        if (notes) t("搜索笔记", "Search notes")
                        else t("搜索名称、账号或网站", "Search titles, usernames, domains…"),
                        maxLines = 1,
                    )
                },
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                trailingIcon = {
                    if (search.isNotEmpty())
                        IconButton(
                            onClick = {
                                search = ""
                                ui.selectedIds.value = emptySet()
                            }
                        ) {
                            Icon(Icons.Outlined.Close, t("清空搜索", "Clear search"))
                        }
                },
                shape = RoundedCornerShape(if (notes) 16.dp else 12.dp),
                colors =
                    OutlinedTextFieldDefaults.colors(
                        unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                        focusedContainerColor = MaterialTheme.colorScheme.surface,
                        unfocusedBorderColor =
                            if (notes) Color.Transparent
                            else MaterialTheme.colorScheme.outlineVariant,
                    ),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            )
            if (!compact) {
                if (notes)
                    Row(
                        Modifier.fillMaxWidth().padding(start = 20.dp, top = 10.dp, end = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.weight(1f)) {
                            TextButton(
                                onClick = { folderMenu = true },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                if (LocalDensity.current.fontScale <= 1.25f) {
                                    Icon(Icons.Outlined.FolderOpen, null, Modifier.size(18.dp))
                                    Spacer(Modifier.width(6.dp))
                                }
                                Text(
                                    category.ifEmpty { t("全部笔记", "All notes") },
                                    modifier = Modifier.weight(1f),
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Icon(Icons.Outlined.ExpandMore, null)
                            }
                            DropdownMenu(
                                expanded = folderMenu,
                                onDismissRequest = { folderMenu = false },
                            ) {
                                (listOf("") + categories).forEach { value ->
                                    DropdownMenuItem(
                                        text = { Text(value.ifEmpty { t("全部笔记", "All notes") }) },
                                        onClick = {
                                            category = value
                                            ui.selectedIds.value = emptySet()
                                            folderMenu = false
                                        },
                                    )
                                }
                                HorizontalDivider()
                                DropdownMenuItem(
                                    text = { Text(t("管理分类", "Manage folders")) },
                                    onClick = {
                                        folderMenu = false
                                        manageCategories()
                                    },
                                )
                            }
                        }
                        Text(
                            "${filtered.size}",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        IconButton(onClick = { grid = !grid }) {
                            Icon(
                                if (grid) Icons.Outlined.ViewAgenda else Icons.Outlined.GridView,
                                if (grid) t("切换列表", "List view") else t("切换网格", "Grid view"),
                            )
                        }
                        Box {
                            IconButton(onClick = { sortMenu = true }) {
                                Icon(
                                    if (favorites) Icons.Outlined.Star else Icons.Outlined.Sort,
                                    t("筛选与排序", "Filter and sort"),
                                )
                            }
                            DropdownMenu(
                                expanded = sortMenu,
                                onDismissRequest = { sortMenu = false },
                            ) {
                                DropdownMenuItem(
                                    text = {
                                        Text(
                                            if (favorites) t("查看全部笔记", "Show all notes")
                                            else t("仅看收藏", "Favorites only")
                                        )
                                    },
                                    onClick = {
                                        favorites = !favorites
                                        ui.selectedIds.value = emptySet()
                                        sortMenu = false
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(t("最近修改", "Recently updated")) },
                                    onClick = {
                                        setSort("updatedDesc")
                                        sortMenu = false
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(t("最早修改", "Oldest updated")) },
                                    onClick = {
                                        setSort("updatedAsc")
                                        sortMenu = false
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(t("标题降序", "Title Z–A")) },
                                    onClick = {
                                        setSort("titleDesc")
                                        sortMenu = false
                                    },
                                )
                                DropdownMenuItem(
                                    text = { Text(t("按标题", "By title")) },
                                    onClick = {
                                        setSort("titleAsc")
                                        sortMenu = false
                                    },
                                )
                            }
                        }
                        if (inlineNoteTools)
                            CollectionTools(
                                page,
                                ui,
                                filtered,
                                state,
                                vault,
                                t,
                                manageCategories,
                                operationScope,
                                compactActions = true,
                            )
                    }
                else if (categories.isNotEmpty()) {
                    Row(
                        Modifier.horizontalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        (listOf("") + categories).forEach { value ->
                            FilterChip(
                                selected = category == value,
                                onClick = {
                                    category = value
                                    ui.selectedIds.value = emptySet()
                                },
                                label = { Text(value.ifEmpty { t("全部", "All") }) },
                                shape = RoundedCornerShape(24.dp),
                                colors =
                                    FilterChipDefaults.filterChipColors(
                                        selectedContainerColor = MaterialTheme.colorScheme.primary,
                                        selectedLabelColor = MaterialTheme.colorScheme.onPrimary,
                                    ),
                            )
                        }
                    }
                }
                if (!notes && tags.isNotEmpty())
                    Row(
                        Modifier.horizontalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        (listOf("") + tags).forEach { value ->
                            FilterChip(
                                selected = tag == value,
                                onClick = {
                                    tag = value
                                    ui.selectedIds.value = emptySet()
                                },
                                label = { Text(value.ifEmpty { t("全部标签", "All tags") }) },
                            )
                        }
                    }
            }
            if (page != "trash" && !inlineNoteTools)
                CollectionTools(
                    page,
                    ui,
                    filtered,
                    state,
                    vault,
                    t,
                    manageCategories,
                    operationScope,
                )
            if (!notes)
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        t(
                            "${filtered.size} ${if (notes) "篇笔记" else "项资料"}",
                            "${filtered.size} ${if (notes) "notes" else "items"}",
                        ),
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.weight(1f))
                    IconToggleButton(
                        checked = favorites,
                        onCheckedChange = {
                            favorites = it
                            ui.selectedIds.value = emptySet()
                        },
                    ) {
                        Icon(
                            if (favorites) Icons.Outlined.Star else Icons.Outlined.StarOutline,
                            t("仅看收藏", "Favorites only"),
                        )
                    }
                    Box {
                        IconButton(onClick = { sortMenu = true }) {
                            Icon(Icons.Outlined.Sort, t("排序", "Sort"))
                        }
                        DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                            DropdownMenuItem(
                                text = { Text(t("最近修改", "Recently updated")) },
                                onClick = {
                                    setSort("updatedDesc")
                                    sortMenu = false
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(t("标题降序", "Title Z–A")) },
                                onClick = {
                                    setSort("titleDesc")
                                    sortMenu = false
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(t("最早修改", "Oldest updated")) },
                                onClick = {
                                    setSort("updatedAsc")
                                    sortMenu = false
                                },
                            )
                            DropdownMenuItem(
                                text = { Text(t("按标题", "By title")) },
                                onClick = {
                                    setSort("titleAsc")
                                    sortMenu = false
                                },
                            )
                        }
                    }
                }
        }
    }
    val emptyState: @Composable () -> Unit = {
        Column(
            Modifier.fillMaxWidth().padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                if (notes) Icons.Outlined.Description else Icons.Outlined.Search,
                null,
                Modifier.size(36.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                if (page == "trash" && source.isEmpty()) t("回收站为空", "Trash is empty")
                else if (source.isEmpty()) t("还没有资料", "Nothing here yet")
                else t("没有匹配的资料", "No matching entries"),
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                if (page == "trash" && source.isEmpty())
                    t("删除的资料会显示在这里。", "Deleted entries will appear here.")
                else if (source.isEmpty()) t("点击右下角 +，开始记录。", "Tap + to create your first entry.")
                else t("试试其他关键词，或清除筛选。", "Try another search or clear your filters."),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (source.isNotEmpty())
                TextButton(
                    onClick = {
                        search = ""
                        category = ""
                        tag = ""
                        favorites = false
                        ui.vaultFilter.value = "*"
                        ui.selectedIds.value = emptySet()
                    }
                ) {
                    Text(t("清除筛选", "Clear filters"))
                }
        }
    }
    if (notes)
        Column(Modifier.fillMaxSize()) {
            header()
            if (filtered.isEmpty()) emptyState()
            else if (grid) {
                val minimum = if (LocalDensity.current.fontScale > 1.2f) 210.dp else 160.dp
                LazyVerticalStaggeredGrid(
                    columns = StaggeredGridCells.Adaptive(minimum),
                    state = ui.masonry,
                    modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 100.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalItemSpacing = 12.dp,
                ) {
                    gridItems(filtered, key = { it.getString("id") }) { item ->
                        NoteCard(
                            item,
                            vault,
                            t,
                            { openItem(item) },
                            { edit(item) },
                            { delete(item) },
                            selection =
                                if (ui.selecting.value) item.optString("id") in ui.selectedIds.value
                                else null,
                        )
                    }
                }
            } else
                LazyColumn(
                    Modifier.weight(1f).fillMaxWidth(),
                    state = ui.list,
                    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 100.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(filtered, key = { it.getString("id") }) { item ->
                        if (item.optString("type") == "secureNote")
                            NoteCard(
                                item,
                                vault,
                                t,
                                { openItem(item) },
                                { edit(item) },
                                { delete(item) },
                                selection =
                                    if (ui.selecting.value)
                                        item.optString("id") in ui.selectedIds.value
                                    else null,
                            )
                        else
                            CredentialCard(
                                item,
                                vault,
                                t,
                                { openItem(item) },
                                { edit(item) },
                                { delete(item) },
                            )
                    }
                }
        }
    else {
        LazyColumn(
            state = ui.list,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 100.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "collection-controls") { header() }
            if (filtered.isEmpty()) item(key = "empty") { emptyState() }
            items(filtered, key = { it.getString("id") }) { item ->
                Box(Modifier.padding(horizontal = 20.dp)) {
                    if (item.optString("type") == "secureNote")
                        NoteCard(
                            item,
                            vault,
                            t,
                            { openItem(item) },
                            { edit(item) },
                            { delete(item) },
                            selection =
                                if (ui.selecting.value) item.optString("id") in ui.selectedIds.value
                                else null,
                        )
                    else
                        CredentialCard(
                            item,
                            vault,
                            t,
                            { openItem(item) },
                            { edit(item) },
                            { delete(item) },
                            selection =
                                if (ui.selecting.value) item.optString("id") in ui.selectedIds.value
                                else null,
                        )
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
private fun CredentialCard(
    item: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    open: () -> Unit,
    edit: () -> Unit,
    delete: () -> Unit,
    selection: Boolean? = null,
) {
    val scope = rememberCoroutineScope()
    var code by remember(item.optString("id")) { mutableStateOf("") }
    var menu by remember { mutableStateOf(false) }
    var copyMenu by remember { mutableStateOf(false) }
    var remaining by remember { mutableIntStateOf(0) }
    val extra = item.optJSONArray("accounts")?.objects().orEmpty()
    val period = item.optInt("period", 30).coerceAtLeast(1)
    val hasCode =
        item.optString("secret").isNotBlank() &&
            item.optString("type") in listOf("password", "totp")
    LaunchedEffect(item.toString()) {
        if (hasCode && !item.optBoolean("isDeleted"))
            while (true) {
                remaining = period - ((System.currentTimeMillis() / 1000) % period).toInt()
                code =
                    runCatching {
                            vault
                                .command(
                                    "totp",
                                    JSONObject()
                                        .put("secret", item.optString("secret"))
                                        .put("period", item.optInt("period", 30))
                                        .put("time", System.currentTimeMillis() / 1000),
                                )
                                .optString("code")
                        }
                        .getOrDefault("")
                delay(1000)
            }
    }
    Surface(
        modifier =
            Modifier.combinedClickable(
                onClick = {
                    if (selection != null) open()
                    else if (item.optString("type") == "totp" && !item.optBoolean("isDeleted")) {
                        if (code.isNotEmpty()) vault.copy(code)
                    } else open()
                },
                onLongClick = {
                    if (selection != null) open()
                    else if (item.optString("type") == "totp" || !vault.canEdit(item)) menu = true
                    else delete()
                },
            ),
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface,
        border =
            BorderStroke(
                if (item.optString("colorLabel").isBlank()) 1.dp else 2.dp,
                legacyItemColor(item.optString("colorLabel"))
                    ?: MaterialTheme.colorScheme.outlineVariant,
            ),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (selection != null)
                    Checkbox(
                        checked = selection,
                        enabled = vault.canEdit(item),
                        onCheckedChange = { open() },
                    )
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceContainerHigh,
                ) {
                    Box(Modifier.size(42.dp), contentAlignment = Alignment.Center) {
                        Text(
                            item.optString("title").take(1).uppercase(),
                            style = MaterialTheme.typography.titleLarge,
                        )
                    }
                }
                Column(Modifier.weight(1f)) {
                    Text(
                        item.optString("title"),
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        item
                            .optString(
                                if (item.optString("type") == "crypto") "address" else "username"
                            )
                            .ifEmpty { item.optString("url") },
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (item.optBoolean("isPinned"))
                    Icon(
                        Icons.Outlined.PushPin,
                        t("已置顶", "Pinned"),
                        Modifier.size(16.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
            }
            if (code.isNotEmpty())
                Row(
                    Modifier.fillMaxWidth().clickable(enabled = selection == null) {
                        vault.copy(code)
                    },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        code.chunked(3).joinToString(" "),
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.headlineMedium,
                        fontFamily = FontFamily.Monospace,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Box(contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(
                            progress = { remaining.toFloat() / period },
                            modifier = Modifier.size(36.dp),
                            strokeWidth = 3.dp,
                        )
                        Text("$remaining", style = MaterialTheme.typography.labelSmall)
                    }
                }
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                val badges = mutableListOf<String>()
                if (extra.isNotEmpty())
                    badges += t("账号 · ${extra.size + 1}", "Accounts · ${extra.size + 1}")
                badges += entryTags(item)
                if (item.optString("type") == "password") {
                    if (
                        item.optString("password").length < 12 ||
                            extra.any { it.optString("password").length < 12 }
                    )
                        badges += t("弱密码", "Weak password")
                    val own = listOf(item) + extra
                    val all =
                        vault.state.value.entries
                            .filter {
                                it.optString("type") == "password" && !it.optBoolean("isDeleted")
                            }
                            .flatMap {
                                listOf(it) + it.optJSONArray("accounts")?.objects().orEmpty()
                            }
                    if (
                        own.any { account ->
                            account.optString("password").isNotEmpty() &&
                                all.count {
                                    it.optString("password") == account.optString("password")
                                } > 1
                        }
                    )
                        badges += t("重复密码", "Reused password")
                    val duration = item.optInt("passwordDuration")
                    if (duration > 0)
                        runCatching {
                            val expires =
                                Instant.parse(item.optString("passwordLastChanged"))
                                    .plusSeconds(duration.toLong() * 86400)
                                    .toEpochMilli()
                            val days = (expires - System.currentTimeMillis()) / 86400000
                            if (expires < System.currentTimeMillis()) badges += t("已过期", "Expired")
                            else if (days <= 7)
                                badges += t("${days} 天后到期", "Expires in ${days} days")
                        }
                }
                badges.forEach { label ->
                    Surface(
                        shape = RoundedCornerShape(7.dp),
                        color = MaterialTheme.colorScheme.surfaceContainerLow,
                    ) {
                        Text(
                            label,
                            Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(
                    enabled =
                        selection == null && vault.canEdit(item) && !item.optBoolean("isDeleted"),
                    onClick = {
                        scope.launch {
                            vault.save(
                                JSONObject(item.toString())
                                    .put("isFavorite", !item.optBoolean("isFavorite"))
                            )
                        }
                    },
                ) {
                    Icon(
                        if (item.optBoolean("isFavorite")) Icons.Outlined.Star
                        else Icons.Outlined.StarOutline,
                        t("收藏", "Favorite"),
                        tint =
                            if (item.optBoolean("isFavorite")) MaterialTheme.colorScheme.primary
                            else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                val copyValue =
                    when (item.optString("type")) {
                        "totp" -> code
                        "crypto" -> item.optString("address")
                        else -> item.optString("password")
                    }
                Box {
                    IconButton(
                        enabled =
                            selection == null &&
                                (copyValue.isNotEmpty() || extra.isNotEmpty()) &&
                                !item.optBoolean("isDeleted"),
                        onClick = {
                            if (item.optString("type") == "password" && extra.isNotEmpty())
                                copyMenu = true
                            else vault.copy(copyValue)
                        },
                    ) {
                        Icon(Icons.Outlined.ContentCopy, t("复制", "Copy"))
                    }
                    DropdownMenu(expanded = copyMenu, onDismissRequest = { copyMenu = false }) {
                        (listOf(item) + extra).forEachIndexed { index, account ->
                            DropdownMenuItem(
                                text = {
                                    Text(
                                        (if (index == 0) t("默认账号", "Default account")
                                        else
                                            account.optString("label").ifEmpty {
                                                t("账号 ${index + 1}", "Account ${index + 1}")
                                            }) + " · " + account.optString("username")
                                    )
                                },
                                onClick = {
                                    vault.copy(account.optString("password"))
                                    copyMenu = false
                                },
                            )
                        }
                    }
                }
                Box {
                    IconButton(enabled = selection == null, onClick = { menu = true }) {
                        Icon(Icons.Outlined.MoreHoriz, t("更多", "More"))
                    }
                    EntryMenu(menu, { menu = false }, item, vault, t, edit, delete)
                }
                Spacer(Modifier.weight(1f))
                if (!vault.canEdit(item))
                    Text(
                        t("只读", "Read only"),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteCard(
    item: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    open: () -> Unit,
    edit: () -> Unit,
    delete: () -> Unit,
    selection: Boolean? = null,
) {
    var menu by remember { mutableStateOf(false) }
    Box {
        Surface(
            shape = RoundedCornerShape(18.dp),
            color = MaterialTheme.colorScheme.surface,
            border =
                if (selection == true) BorderStroke(2.dp, MaterialTheme.colorScheme.primary)
                else null,
            modifier =
                Modifier.fillMaxWidth()
                    .combinedClickable(
                        onClick = open,
                        onLongClick = { if (selection != null) open() else menu = true },
                        onLongClickLabel = t("笔记操作", "Note actions"),
                    ),
        ) {
            Column(
                Modifier.padding(14.dp).heightIn(min = 128.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Row(verticalAlignment = Alignment.Top) {
                    if (selection != null)
                        Checkbox(
                            checked = selection,
                            onCheckedChange = { open() },
                            enabled = vault.canEdit(item),
                        )
                    Text(
                        item.optString("title").ifEmpty { t("未命名笔记", "Untitled note") },
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (item.optBoolean("isPinned"))
                        Icon(
                            Icons.Outlined.PushPin,
                            t("已置顶", "Pinned"),
                            Modifier.size(16.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    else if (item.optBoolean("isFavorite"))
                        Icon(
                            Icons.Outlined.Star,
                            t("已收藏", "Favorite"),
                            Modifier.size(16.dp),
                            tint = Color(0xFFC48B0B),
                        )
                }
                val preview =
                    item
                        .optString("note")
                        .replace(Regex("(?m)^\\s{0,3}(#+\\s*|[-*+]\\s+)"), "")
                        .replace("**", "")
                        .trim()
                if (preview.isNotEmpty())
                    Text(
                        preview,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 4,
                        overflow = TextOverflow.Ellipsis,
                    )
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (item.optString("category").isNotEmpty())
                            Text(
                                item.optString("category"),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        Text(
                            noteDate(item),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(
                        enabled = selection == null,
                        onClick = { menu = true },
                        modifier = Modifier.size(48.dp),
                    ) {
                        Icon(Icons.Outlined.MoreHoriz, t("更多", "More"), Modifier.size(20.dp))
                    }
                }
            }
        }
        EntryMenu(menu, { menu = false }, item, vault, t, edit, delete)
    }
}

@Composable
internal fun EntryMenu(
    expanded: Boolean,
    dismiss: () -> Unit,
    item: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    edit: () -> Unit,
    delete: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    val editable = vault.canEdit(item)
    DropdownMenu(expanded = expanded, onDismissRequest = dismiss) {
        if (!item.optBoolean("isDeleted")) {
            if (item.optString("type") == "totp")
                DropdownMenuItem(
                    text = { Text(t("导出 otpauth 链接", "Export otpauth link")) },
                    onClick = {
                        dismiss()
                        vault.copy(totpSetupUri(item))
                    },
                )
            DropdownMenuItem(
                text = { Text(t("编辑", "Edit")) },
                onClick = {
                    dismiss()
                    edit()
                },
                enabled = editable,
            )
            for ((field, label) in
                listOf(
                    "isPinned" to
                        if (item.optBoolean("isPinned")) t("取消置顶", "Unpin") else t("置顶", "Pin"),
                    "isFavorite" to
                        if (item.optBoolean("isFavorite")) t("取消收藏", "Unfavorite")
                        else t("收藏", "Favorite"),
                )) {
                DropdownMenuItem(
                    text = { Text(label) },
                    onClick = {
                        dismiss()
                        scope.launch {
                            vault.save(
                                JSONObject(item.toString()).put(field, !item.optBoolean(field))
                            )
                        }
                    },
                    enabled = editable,
                )
            }
        } else
            DropdownMenuItem(
                text = { Text(t("恢复", "Restore")) },
                onClick = {
                    dismiss()
                    scope.launch { vault.trash(item) }
                },
                enabled = editable,
            )
        HorizontalDivider()
        DropdownMenuItem(
            text = {
                Text(
                    if (item.optBoolean("isDeleted")) t("永久删除…", "Delete permanently…")
                    else t("删除…", "Delete…"),
                    color = MaterialTheme.colorScheme.error,
                )
            },
            leadingIcon = { Icon(Icons.Outlined.DeleteOutline, null) },
            onClick = {
                dismiss()
                delete()
            },
            enabled =
                editable &&
                    !(item.optBoolean("isDeleted") && item.optString("sharedVaultId").isNotEmpty()),
        )
        if (!editable)
            DropdownMenuItem(
                text = { Text(t("此共享资料为只读", "This shared entry is read only")) },
                onClick = {},
                enabled = false,
            )
    }
}
