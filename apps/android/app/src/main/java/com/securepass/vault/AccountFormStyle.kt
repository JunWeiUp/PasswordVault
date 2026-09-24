package com.securepass.vault

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp

// The account refresh is deliberately scoped; code/wallet editors retain their existing style.
internal val LocalAccountForm = staticCompositionLocalOf { false }

@Composable
internal fun accountFieldColor() =
    if (MaterialTheme.colorScheme.surface.luminance() < 0.5f)
        MaterialTheme.colorScheme.surfaceContainerHigh
    else MaterialTheme.colorScheme.surfaceContainerLow

@Composable
internal fun EditorFormSection(content: @Composable ColumnScope.() -> Unit) {
    if (LocalAccountForm.current) {
        Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(18.dp)) {
            Column(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                content = content,
            )
        }
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
