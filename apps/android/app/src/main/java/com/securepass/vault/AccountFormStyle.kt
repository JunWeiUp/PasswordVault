package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

// Shared native form geometry follows the Android design's external labels and surface inputs.
internal val LocalAccountForm = staticCompositionLocalOf { false }

@Composable
internal fun accountFieldColor() =
    MaterialTheme.colorScheme.surface

@Composable
internal fun EditorFormSection(content: @Composable ColumnScope.() -> Unit) {
    if (LocalAccountForm.current) {
        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content,
        )
    } else LegacySection(content)
}

@Composable
internal fun EditorActionButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    content: @Composable RowScope.() -> Unit,
) {
    if (LocalAccountForm.current) {
        FilledTonalButton(
            onClick = onClick,
            modifier = modifier.heightIn(min = 48.dp),
            enabled = enabled,
            shape = RoundedCornerShape(12.dp),
            content = content,
        )
    } else
        OutlinedButton(onClick = onClick, modifier = modifier, enabled = enabled, content = content)
}
