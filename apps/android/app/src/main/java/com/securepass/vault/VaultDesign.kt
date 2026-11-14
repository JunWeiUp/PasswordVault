package com.securepass.vault

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Shared Mac / Android design tokens. Persisted appearance settings remain compatible.
@Composable
fun LegacyVaultTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors =
        if (dark)
            darkColorScheme(
                secondaryContainer = Color(0xFF283653),
                onSecondaryContainer = Color(0xFFC8D5FF),
                primary = Color(0xFF7AA2FF),
                onPrimary = Color(0xFF0C1834),
                primaryContainer = Color(0xFF243250),
                onPrimaryContainer = Color(0xFFDFe8FF),
                background = Color(0xFF121419),
                surface = Color(0xFF1C2027),
                surfaceContainer = Color(0xFF262B34),
                surfaceContainerLow = Color(0xFF1C2027),
                surfaceContainerHigh = Color(0xFF2B313B),
                onSurface = Color(0xFFF0F1F5),
                onSurfaceVariant = Color(0xFFB6BECC),
                outlineVariant = Color(0xFF363D4B),
            )
        else
            lightColorScheme(
                secondaryContainer = Color(0xFFE8EEFB),
                onSecondaryContainer = Color(0xFF3265DB),
                primary = Color(0xFF3265DB),
                onPrimary = Color.White,
                primaryContainer = Color(0xFFE8EEFB),
                onPrimaryContainer = Color(0xFF173469),
                background = Color(0xFFF3F5F8),
                surface = Color.White,
                surfaceContainer = Color(0xFFEEF1F6),
                surfaceContainerLow = Color(0xFFF7F8FA),
                surfaceContainerHigh = Color(0xFFEDF0F4),
                onSurface = Color(0xFF242A35),
                onSurfaceVariant = Color(0xFF5C6573),
                outlineVariant = Color(0xFFE4E8EF),
            )
    val base = Typography()
    MaterialTheme(
        colorScheme = colors,
        typography =
            base.copy(
                headlineLarge =
                    base.headlineLarge.copy(fontSize = 32.sp, fontWeight = FontWeight.Bold),
                headlineMedium =
                    base.headlineMedium.copy(
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Medium,
                        letterSpacing = 0.sp,
                    ),
                titleLarge = base.titleLarge.copy(fontSize = 20.sp, fontWeight = FontWeight.Medium),
                titleMedium =
                    base.titleMedium.copy(fontSize = 14.sp, fontWeight = FontWeight.Medium),
                bodyLarge = base.bodyLarge.copy(fontSize = 14.sp, lineHeight = 21.sp),
                bodyMedium = base.bodyMedium.copy(fontSize = 14.sp, lineHeight = 21.sp),
            ),
        shapes =
            Shapes(
                small = RoundedCornerShape(12.dp),
                medium = RoundedCornerShape(14.dp),
                large = RoundedCornerShape(18.dp),
            ),
        content = content,
    )
}

@Composable
fun LegacySection(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
    ) {
        Column(
            Modifier.fillMaxWidth().padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
            content = content,
        )
    }
}
