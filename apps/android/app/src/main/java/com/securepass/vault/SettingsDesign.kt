package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Dimensions from the Android reference (14px base), confined to settings and authentication.
@Composable
internal fun SettingsCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(shape = RoundedCornerShape(16.dp), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth(), content = content)
    }
}

@Composable
internal fun SettingsLabel(text: String) {
    Text(text, Modifier.padding(start = 8.dp, top = 5.dp), color = MaterialTheme.colorScheme.primary,
        fontSize = 11.5.sp, fontWeight = FontWeight.SemiBold)
}

@Composable
internal fun SettingsRule() {
    HorizontalDivider(Modifier.padding(start = 15.dp), thickness = 0.5.dp,
        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
}

@Composable
internal fun SettingsOption(
    title: String,
    subtitle: String = "",
    trailing: @Composable () -> Unit = {},
) {
    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 15.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal)
            if (subtitle.isNotEmpty()) Text(subtitle, fontSize = 12.sp, lineHeight = 17.sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        trailing()
    }
}

@Composable
internal fun SettingsDetail(content: @Composable ColumnScope.() -> Unit) {
    SettingsCard {
        Column(Modifier.padding(15.dp), verticalArrangement = Arrangement.spacedBy(12.dp), content = content)
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsChoiceOption(
    title: String,
    subtitle: String = "",
    value: String,
    options: List<String>,
    onSelect: (String) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 14.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal)
            if (subtitle.isNotEmpty()) {
                Text(subtitle, fontSize = 12.sp, lineHeight = 17.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        if (options.size <= 4 && options.all { it.length <= 6 }) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                options.forEachIndexed { index, option ->
                    SegmentedButton(
                        selected = option == value,
                        onClick = { onSelect(option) },
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
                        icon = {},
                    ) {
                        Text(option, fontSize = 12.sp, maxLines = 1)
                    }
                }
            }
        } else if (options.size <= 6) {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                options.forEach { option ->
                    val selected = option == value
                    FilterChip(
                        selected = selected,
                        onClick = { onSelect(option) },
                        label = { Text(option, fontSize = 12.sp) },
                        colors = FilterChipDefaults.filterChipColors(
                            containerColor = MaterialTheme.colorScheme.surface,
                            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
                            selectedLabelColor = MaterialTheme.colorScheme.primary,
                        ),
                    )
                }
            }
        } else {
            SettingsChoice(value, options, onSelect)
        }
    }
}

@Composable
internal fun SettingsChoice(value: String, options: List<String>, onSelect: (String) -> Unit) {
    var expanded by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    Box {
        Surface(onClick = { expanded = true }, shape = RoundedCornerShape(8.dp), color = MaterialTheme.colorScheme.surfaceContainer) {
            Text(value, Modifier.padding(horizontal = 8.dp, vertical = 6.dp), fontSize = 12.sp)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEach { option -> DropdownMenuItem(text = { Text(option) }, onClick = { expanded = false; onSelect(option) }) }
        }
    }
}

@Composable
internal fun SettingsBrand(icon: ImageVector) {
    Surface(Modifier.size(64.dp), shape = RoundedCornerShape(18.dp), color = MaterialTheme.colorScheme.primary) {
        Box(contentAlignment = Alignment.Center) {
            Icon(icon, null, Modifier.size(34.dp), tint = MaterialTheme.colorScheme.onPrimary)
        }
    }
}

@Composable
internal fun AuthenticationSteps(step: Int) {
    Row(Modifier.padding(bottom = 17.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        repeat(3) { index ->
            Surface(Modifier.width(if (index == step) 20.dp else 7.dp).height(7.dp),
                shape = RoundedCornerShape(10.dp),
                color = if (index == step) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant) {}
        }
    }
}

@Composable
internal fun AuthenticationInput(
    label: String, value: String, onChange: (String) -> Unit, enabled: Boolean,
    submit: (() -> Unit)? = null, canSubmit: Boolean = false, busy: Boolean = false,
    submitLabel: String = label,
) {
    Column(Modifier.fillMaxWidth()) {
        Text(label, Modifier.padding(start = 5.dp, bottom = 4.dp), fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant, fontWeight = FontWeight.Medium)
        TextField(value, onChange, enabled = enabled, singleLine = true,
            modifier = Modifier.fillMaxWidth().heightIn(min = 49.dp),
            shape = RoundedCornerShape(13.dp),
            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(autoCorrectEnabled = false,
                keyboardType = androidx.compose.ui.text.input.KeyboardType.Password,
                imeAction = if (submit != null) androidx.compose.ui.text.input.ImeAction.Done else androidx.compose.ui.text.input.ImeAction.Next),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { if (canSubmit) submit?.invoke() }),
            trailingIcon = if (submit == null) null else ({
                if (busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                else IconButton(enabled = canSubmit, onClick = submit) {
                    Icon(androidx.compose.material.icons.Icons.Filled.ChevronRight, submitLabel)
                }
            }),
            textStyle = MaterialTheme.typography.bodyMedium,
            colors = TextFieldDefaults.colors(
                unfocusedContainerColor = MaterialTheme.colorScheme.surface,
                focusedContainerColor = MaterialTheme.colorScheme.surface,
                disabledContainerColor = MaterialTheme.colorScheme.surface,
                unfocusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                focusedIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
                disabledIndicatorColor = androidx.compose.ui.graphics.Color.Transparent,
            ))
    }
}

@Composable
internal fun SettingsHint(text: String) {
    Text(text, Modifier.padding(horizontal = 8.dp), fontSize = 12.sp, lineHeight = 18.sp,
        color = MaterialTheme.colorScheme.onSurfaceVariant)
}
