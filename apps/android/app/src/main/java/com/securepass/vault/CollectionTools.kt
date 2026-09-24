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
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/** Each success is awaited before it is counted. Failed and read-only records remain selected. */
internal suspend fun applyCollectionBatch(
    vault: VaultRepository,
    ids: Set<String>,
    operation: String,
    value: String = "",
): Set<String> {
    val succeeded = mutableSetOf<String>()
    for (id in ids) {
        val item = vault.state.value.entries.firstOrNull { it.optString("id") == id } ?: continue
        if (!vault.canEdit(item)) continue
        val next = JSONObject(item.toString())
        val ok =
            when (operation) {
                "delete" -> if (item.optBoolean("isDeleted")) true else vault.trash(item)
                "pin",
                "unpin" -> vault.save(next.put("isPinned", operation == "pin"))
                "tag" ->
                    vault.save(
                        next.put(
                            "tags",
                            JSONArray(
                                (entryTags(item) + value).filter { it.isNotBlank() }.distinct()
                            ),
                        )
                    )
                "color" -> vault.save(next.put("colorLabel", value))
                else -> false
            }
        if (ok) succeeded += id
    }
    return succeeded
}

internal class CollectionToolsState {
    val menu = mutableStateOf(false)
    val filterMenu = mutableStateOf(false)
    val operation = mutableStateOf<String?>(null)
    val value = mutableStateOf("")
    val busy = mutableStateOf(false)
    val result = mutableStateOf<String?>(null)
    val bulkTotp = mutableStateOf(false)
    val lines = mutableStateOf("")
    val cachedInput = mutableStateOf("")
    val parsed = mutableStateOf<List<JSONObject>>(emptyList())
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun CollectionTools(
    page: String,
    ui: CollectionUiState,
    filtered: List<JSONObject>,
    state: VaultState,
    vault: VaultRepository,
    t: (String, String) -> String,
    backup: () -> Unit,
    scope: kotlinx.coroutines.CoroutineScope,
) {
    var selecting by ui.selecting
    var ids by ui.selectedIds
    var filter by ui.vaultFilter
    var menu by ui.tools.menu
    var filterMenu by ui.tools.filterMenu
    var operation by ui.tools.operation
    var value by ui.tools.value
    var busy by ui.tools.busy
    var result by ui.tools.result
    var bulkTotp by ui.tools.bulkTotp
    var lines by ui.tools.lines
    var cachedInput by ui.tools.cachedInput
    var parsed by ui.tools.parsed
    Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (state.sharedVaults.isNotEmpty())
                Box(Modifier.weight(1f)) {
                    TextButton(onClick = { filterMenu = true }) {
                        Icon(Icons.Outlined.FolderShared, null, Modifier.size(18.dp))
                        Text(
                            when (filter) {
                                "*" -> t("全部资料库", "All vaults")
                                "" -> t("个人资料库", "Personal vault")
                                else ->
                                    state.sharedVaults
                                        .firstOrNull { it.optString("id") == filter }
                                        ?.optString("name")
                                        .orEmpty()
                            }
                        )
                    }
                    DropdownMenu(filterMenu, { filterMenu = false }) {
                        (listOf(
                                "*" to t("全部资料库", "All vaults"),
                                "" to t("个人资料库", "Personal vault"),
                            ) +
                                state.sharedVaults.map {
                                    it.optString("id") to it.optString("name")
                                })
                            .forEach { (id, name) ->
                                DropdownMenuItem(
                                    text = { Text(name) },
                                    onClick = {
                                        filter = id
                                        ids = emptySet()
                                        filterMenu = false
                                    },
                                )
                            }
                    }
                }
            else Spacer(Modifier.weight(1f))
            TextButton(
                enabled = !busy,
                onClick = {
                    selecting = !selecting
                    ids = emptySet()
                    result = null
                },
            ) {
                Text(if (selecting) t("完成选择", "Done selecting") else t("选择", "Select"))
            }
            Box {
                IconButton(enabled = !busy, onClick = { menu = true }) {
                    Icon(Icons.Outlined.MoreVert, t("资料工具", "Collection tools"))
                }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(
                        text = { Text(t("导入 / 导出", "Import / export")) },
                        onClick = {
                            menu = false
                            backup()
                        },
                    )
                    if (page == "totp")
                        DropdownMenuItem(
                            text = { Text(t("批量导入验证码", "Import multiple codes")) },
                            onClick = {
                                menu = false
                                bulkTotp = true
                            },
                        )
                }
            }
        }
        if (selecting) {
            val eligible = filtered.filter { vault.canEdit(it) }.map { it.optString("id") }.toSet()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(
                    checked = eligible.isNotEmpty() && ids.containsAll(eligible),
                    enabled = !busy,
                    onCheckedChange = { ids = if (it) eligible else emptySet() },
                )
                Text(t("已选 ${ids.size} 项", "${ids.size} selected"))
                TextButton(enabled = !busy, onClick = { ids = eligible }) {
                    Text(t("全选", "Select all"))
                }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(
                        "delete" to t("删除", "Delete"),
                        "pin" to t("置顶", "Pin"),
                        "unpin" to t("取消置顶", "Unpin"),
                        "tag" to t("添加标签", "Add tag"),
                        "color" to t("颜色标记", "Color label"),
                    )
                    .forEach { (op, label) ->
                        OutlinedButton(
                            enabled = !busy && ids.isNotEmpty(),
                            onClick = {
                                value = ""
                                operation = op
                            },
                        ) {
                            Text(label)
                        }
                    }
            }
        }
        result?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
    if (operation != null)
        AlertDialog(
            onDismissRequest = { if (!busy) operation = null },
            title = { Text(t("对 ${ids.size} 项执行操作", "Update ${ids.size} selected items")) },
            text = {
                when (operation) {
                    "tag" ->
                        Column(
                            Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())
                        ) {
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                state.entries.flatMap(::entryTags).distinct().sorted().forEach { tag
                                    ->
                                    FilterChip(
                                        selected = value == tag,
                                        onClick = { value = tag },
                                        enabled = !busy,
                                        label = { Text(tag) },
                                    )
                                }
                            }
                            OutlinedTextField(
                                value,
                                { value = it },
                                enabled = !busy,
                                label = { Text(t("标签", "Tag")) },
                            )
                        }
                    "color" ->
                        ChoiceEditor(
                            t("颜色标记", "Color label"),
                            value,
                            legacyColors.keys.toList(),
                            t,
                            allowCustom = false,
                        ) {
                            value = it
                        }
                    "delete" ->
                        Text(
                            t(
                                "选中条目将移到回收站，可恢复。",
                                "Selected records will move to Trash and can be restored.",
                            )
                        )
                    "pin" -> Text(t("将选中条目置顶。", "Pin the selected records."))
                    else -> Text(t("取消选中条目的置顶。", "Unpin the selected records."))
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !busy && (operation != "tag" || value.isNotBlank()),
                    onClick = {
                        val op = operation ?: return@TextButton
                        val selected = ids
                        busy = true
                        scope.launch {
                            val successes = applyCollectionBatch(vault, selected, op, value.trim())
                            ids -= successes
                            result =
                                t(
                                    "已完成 ${successes.size} / ${selected.size} 项" +
                                        if (ids.isEmpty()) "" else "，未完成条目仍保持选中。",
                                    "Completed ${successes.size} / ${selected.size}; unfinished records remain selected.",
                                )
                            busy = false
                            operation = null
                        }
                    },
                ) {
                    Text(t("确认", "Confirm"))
                }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { operation = null }) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
    if (bulkTotp)
        AlertDialog(
            onDismissRequest = { if (!busy) bulkTotp = false },
            title = { Text(t("批量导入验证码", "Import multiple codes")) },
            text = {
                Column {
                    Text(
                        t(
                            "每行一个 otpauth:// 链接，导入前会检查全部行。",
                            "One otpauth:// link per line. All lines are checked before import.",
                        )
                    )
                    Input(
                        t("设置链接", "Setup links"),
                        lines,
                        { lines = it },
                        secret = true,
                        multiline = true,
                        enabled = !busy,
                    )
                    result?.let { Text(it) }
                }
            },
            confirmButton = {
                TextButton(
                    enabled = !busy && lines.isNotBlank(),
                    onClick = {
                        busy = true
                        result = null
                        scope.launch {
                            try {
                                if (cachedInput != lines) {
                                    val ready = mutableListOf<JSONObject>()
                                    for ((index, line) in
                                        lines.lines().filter { it.isNotBlank() }.withIndex()) {
                                        try {
                                            ready +=
                                                vault.command(
                                                    "parse-totp",
                                                    JSONObject().put("uri", line.trim()),
                                                )
                                        } catch (_: Exception) {
                                            error("${index + 1}")
                                        }
                                    }
                                    parsed = ready
                                    cachedInput = lines
                                }
                                var count = 0
                                for (entry in parsed) {
                                    if (filter != "*") entry.put("sharedVaultId", filter)
                                    if (!vault.save(entry)) break
                                    count++
                                }
                                result =
                                    t(
                                        "已导入 $count / ${parsed.size} 项",
                                        "Imported $count / ${parsed.size}",
                                    )
                                if (count == parsed.size) {
                                    bulkTotp = false
                                    lines = ""
                                    parsed = emptyList()
                                    cachedInput = ""
                                }
                            } catch (failure: Exception) {
                                result =
                                    t(
                                        "第 ${failure.message?.toIntOrNull() ?: "?"} 行无效，尚未导入。",
                                        "Invalid line ${failure.message?.toIntOrNull() ?: "?"}; nothing imported.",
                                    )
                            } finally {
                                busy = false
                            }
                        }
                    },
                ) {
                    Text(t("导入", "Import"))
                }
            },
            dismissButton = {
                TextButton(enabled = !busy, onClick = { bulkTotp = false }) {
                    Text(t("取消", "Cancel"))
                }
            },
        )
}
