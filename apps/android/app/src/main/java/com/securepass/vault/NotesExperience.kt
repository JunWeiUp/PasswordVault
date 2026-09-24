package com.securepass.vault

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.window.SecureFlagPolicy
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

@Composable
internal fun NoteReader(
    item: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    delete: () -> Unit,
    restore: () -> Unit,
) {
    var info by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            item.optString("title").ifEmpty { t("未命名笔记", "Untitled note") },
            style = MaterialTheme.typography.headlineMedium,
        )
        Text(
            listOf(
                    noteDate(item),
                    item.optString("category"),
                    t(
                        "${item.optString("note").length} 字符",
                        "${item.optString("note").length} characters",
                    ),
                )
                .filter { it.isNotEmpty() }
                .joinToString(" · "),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (item.optString("note").isNotEmpty()) MarkdownNote(item.optString("note"))
        Spacer(Modifier.height(20.dp))
        TextButton(onClick = { info = true }) {
            Icon(Icons.Outlined.Info, null, Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(t("笔记信息", "Note information"))
        }
        if (item.optBoolean("isDeleted") && vault.canEdit(item))
            Button(onClick = restore) { Text(t("恢复", "Restore")) }
        TextButton(
            enabled =
                vault.canEdit(item) &&
                    !(item.optBoolean("isDeleted") && item.optString("sharedVaultId").isNotEmpty()),
            onClick = delete,
        ) {
            Text(t("删除…", "Delete…"), color = MaterialTheme.colorScheme.error)
        }
    }
    if (info)
        AlertDialog(
            onDismissRequest = { info = false },
            title = { Text(t("笔记信息", "Note information")) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        t("分类：", "Folder: ") +
                            item.optString("category").ifEmpty { t("未分类", "Unfiled") }
                    )
                    Text(
                        t("标签：", "Tags: ") +
                            entryTags(item).joinToString(" · ").ifEmpty { t("无", "None") }
                    )
                    Text(t("修改时间：", "Updated: ") + noteDate(item))
                    if (!vault.canEdit(item)) Text(t("此共享笔记为只读", "This shared note is read only"))
                }
            },
            confirmButton = { TextButton(onClick = { info = false }) { Text(t("完成", "Done")) } },
        )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun NoteEditor(
    original: JSONObject,
    vault: VaultRepository,
    t: (String, String) -> String,
    restoredDraft: Boolean,
    close: () -> Unit,
) {
    var title by remember { mutableStateOf(original.optString("title")) }
    var body by remember { mutableStateOf(TextFieldValue(original.optString("note"))) }
    var category by remember { mutableStateOf(original.optString("category")) }
    var tags by remember { mutableStateOf(entryTags(original).joinToString(", ")) }
    var shared by remember { mutableStateOf(original.optString("sharedVaultId")) }
    var information by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var leaving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    fun snapshot() =
        JSONObject(original.toString())
            .put("title", title)
            .put("note", body.text)
            .put("category", category)
            .put(
                "tags",
                JSONArray(
                    tags.replace('，', ',').split(',').map { it.trim() }.filter { it.isNotEmpty() }
                ),
            )
            .put("sharedVaultId", shared)
    fun track() {
        vault.pendingDraft = snapshot().toString()
        vault.activity()
    }
    val changed =
        restoredDraft ||
            title != original.optString("title") ||
            body.text != original.optString("note") ||
            category != original.optString("category") ||
            tags != entryTags(original).joinToString(", ") ||
            shared != original.optString("sharedVaultId") ||
            vault.state.value.recoveredDraft != null
    val canSave = title.isNotBlank() || body.text.isNotBlank()
    fun cancel() {
        if (changed) leaving = true
        else {
            vault.discardDraft()
            close()
        }
    }
    fun save() {
        if (saving || !canSave) return
        val submitted = snapshot()
        if (submitted.optString("title").isBlank())
            submitted.put(
                "title",
                body.text.lineSequence().firstOrNull { it.isNotBlank() }?.trim()?.take(60)
                    ?: t("未命名笔记", "Untitled note"),
            )
        saving = true
        error = null
        scope.launch {
            try {
                if (vault.save(submitted)) {
                    vault.discardDraft()
                    close()
                } else {
                    leaving = false
                    error = t("尚未保存，请重试。", "Not saved. Please retry.")
                }
            } finally {
                saving = false
            }
        }
    }
    fun format(prefix: String, suffix: String = "") {
        val start = minOf(body.selection.start, body.selection.end)
        val end = maxOf(body.selection.start, body.selection.end)
        val selected = body.text.substring(start, end)
        body =
            TextFieldValue(
                body.text.replaceRange(start, end, prefix + selected + suffix),
                TextRange(start + prefix.length, start + prefix.length + selected.length),
            )
        preview = false
        track()
    }
    Dialog(
        onDismissRequest = { if (!saving) cancel() },
        properties =
            DialogProperties(
                usePlatformDefaultWidth = false,
                dismissOnBackPress = false,
                securePolicy = SecureFlagPolicy.Inherit,
                decorFitsSystemWindows = false,
            ),
    ) {
        NoteDialogBars()
        BackHandler { if (!saving) cancel() }
        Scaffold(
            containerColor = MaterialTheme.colorScheme.background,
            topBar = {
                TopAppBar(
                    colors =
                        TopAppBarDefaults.topAppBarColors(
                            containerColor = MaterialTheme.colorScheme.background
                        ),
                    title = {
                        Text(t("编辑笔记", "Edit note"), style = MaterialTheme.typography.titleMedium)
                    },
                    navigationIcon = {
                        TextButton(enabled = !saving, onClick = ::cancel) {
                            Text(t("取消", "Cancel"))
                        }
                    },
                    actions = {
                        IconButton(enabled = !saving, onClick = { information = true }) {
                            Icon(Icons.Outlined.Info, t("笔记信息", "Note information"))
                        }
                        TextButton(enabled = !saving && canSave, onClick = ::save) {
                            Text(if (saving) t("保存中…", "Saving…") else t("保存", "Save"))
                        }
                    },
                )
            },
            bottomBar = {
                Surface(color = MaterialTheme.colorScheme.surface) {
                    Row(
                        Modifier.fillMaxWidth()
                            .navigationBarsPadding()
                            .imePadding()
                            .padding(horizontal = 12.dp)
                    ) {
                        IconButton(
                            enabled = !saving,
                            onClick = {
                                val position = body.selection.start
                                val lineStart =
                                    if (position == 0) 0
                                    else body.text.lastIndexOf('\n', position - 1) + 1
                                body =
                                    TextFieldValue(
                                        body.text.substring(0, lineStart) +
                                            "## " +
                                            body.text.substring(lineStart),
                                        TextRange(position + 3),
                                    )
                                preview = false
                                track()
                            },
                        ) {
                            Icon(Icons.Outlined.Title, t("插入标题", "Insert heading"))
                        }
                        IconButton(enabled = !saving, onClick = { format("**", "**") }) {
                            Icon(Icons.Outlined.FormatBold, t("加粗", "Bold"))
                        }
                        IconButton(enabled = !saving, onClick = { format("\n- ") }) {
                            Icon(Icons.Outlined.FormatListBulleted, t("项目列表", "Bulleted list"))
                        }
                        Spacer(Modifier.weight(1f))
                        TextButton(enabled = !saving, onClick = { preview = !preview }) {
                            Text(if (preview) t("编辑", "Edit") else t("预览", "Preview"))
                        }
                    }
                }
            },
        ) { padding ->
            Column(
                Modifier.padding(padding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                error?.let {
                    Text(
                        it,
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(8.dp),
                    )
                }
                TextField(
                    value = title,
                    onValueChange = {
                        title = it
                        track()
                    },
                    enabled = !saving && !preview,
                    placeholder = { Text(t("标题", "Title")) },
                    modifier = Modifier.fillMaxWidth(),
                    textStyle = MaterialTheme.typography.headlineMedium,
                    colors = noteFieldColors(),
                    keyboardOptions =
                        androidx.compose.foundation.text.KeyboardOptions(autoCorrectEnabled = false),
                )
                Text(
                    t("${body.text.length} 字符", "${body.text.length} characters") +
                        " · " +
                        if (changed) t("未保存", "Unsaved")
                        else noteDate(original).ifEmpty { t("新笔记", "New note") },
                    Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (preview) Box(Modifier.padding(16.dp)) { MarkdownNote(body.text) }
                else
                    TextField(
                        value = body,
                        onValueChange = {
                            body = it
                            track()
                        },
                        enabled = !saving,
                        placeholder = { Text(t("开始记录…", "Start writing…")) },
                        modifier = Modifier.fillMaxWidth().heightIn(min = 280.dp),
                        minLines = 10,
                        textStyle =
                            MaterialTheme.typography.bodyLarge.copy(
                                fontSize = 18.sp,
                                lineHeight = 30.sp,
                            ),
                        colors = noteFieldColors(),
                        keyboardOptions =
                            androidx.compose.foundation.text.KeyboardOptions(
                                autoCorrectEnabled = false
                            ),
                    )
                Spacer(Modifier.height(24.dp))
            }
        }
        if (information)
            AlertDialog(
                onDismissRequest = { information = false },
                title = { Text(t("笔记信息", "Note information")) },
                text = {
                    Column(
                        Modifier.verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Input(
                            t("分类", "Folder"),
                            category,
                            {
                                category = it
                                track()
                            },
                            enabled = !saving,
                        )
                        Input(
                            t("标签，逗号分隔", "Tags, comma separated"),
                            tags,
                            {
                                tags = it
                                track()
                            },
                            enabled = !saving,
                        )
                        if (vault.state.value.sharedVaults.isNotEmpty()) {
                            Text(t("所属资料库", "Vault"))
                            FilterChip(
                                selected = shared.isEmpty(),
                                onClick = {
                                    shared = ""
                                    track()
                                },
                                label = { Text(t("个人资料库", "Personal vault")) },
                                enabled = !saving,
                            )
                            vault.state.value.sharedVaults.forEach { item ->
                                FilterChip(
                                    selected = shared == item.optString("id"),
                                    onClick = {
                                        shared = item.optString("id")
                                        track()
                                    },
                                    label = {
                                        Text(
                                            item.optString("name") +
                                                if (
                                                    vault.canEdit(
                                                        JSONObject()
                                                            .put(
                                                                "sharedVaultId",
                                                                item.optString("id"),
                                                            )
                                                    )
                                                )
                                                    ""
                                                else t(" · 只读", " · Read only")
                                        )
                                    },
                                    enabled =
                                        !saving &&
                                            vault.canEdit(
                                                JSONObject()
                                                    .put("sharedVaultId", item.optString("id"))
                                            ),
                                )
                            }
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { information = false }) { Text(t("完成", "Done")) }
                },
            )
        if (leaving)
            AlertDialog(
                onDismissRequest = { leaving = false },
                title = { Text(t("保存这次修改？", "Save your changes?")) },
                text = {
                    Text(t("未保存的修改可以继续编辑，或选择放弃。", "Keep editing or discard unsaved changes."))
                },
                confirmButton = {
                    TextButton(enabled = !saving && canSave, onClick = ::save) {
                        Text(t("保存", "Save"))
                    }
                },
                dismissButton = {
                    Row {
                        TextButton(
                            enabled = !saving,
                            onClick = {
                                vault.discardDraft()
                                close()
                            },
                        ) {
                            Text(t("放弃修改", "Discard"), color = MaterialTheme.colorScheme.error)
                        }
                        TextButton(enabled = !saving, onClick = { leaving = false }) {
                            Text(t("继续编辑", "Keep editing"))
                        }
                    }
                },
            )
    }
}

@Composable
private fun noteFieldColors() =
    TextFieldDefaults.colors(
        focusedContainerColor = Color.Transparent,
        unfocusedContainerColor = Color.Transparent,
        disabledContainerColor = Color.Transparent,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
        disabledTextColor = MaterialTheme.colorScheme.onSurface,
        cursorColor = MaterialTheme.colorScheme.primary,
    )

@Composable
private fun NoteDialogBars() {
    val view = LocalView.current
    val background = MaterialTheme.colorScheme.background
    SideEffect {
        val window = (view.parent as? DialogWindowProvider)?.window ?: return@SideEffect
        window.statusBarColor = background.toArgb()
        window.navigationBarColor = background.toArgb()
        androidx.core.view.WindowCompat.getInsetsController(window, view).apply {
            isAppearanceLightStatusBars = background.luminance() > 0.5f
            isAppearanceLightNavigationBars = background.luminance() > 0.5f
        }
    }
}
