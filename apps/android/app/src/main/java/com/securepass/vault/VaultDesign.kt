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

// Mirrors lib/core/theme/app_theme.dart. Notes add their own restrained yellow accent.
@Composable
fun LegacyVaultTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors =
        if (dark)
            darkColorScheme(
                secondaryContainer = Color(0xFF283653),
                onSecondaryContainer = Color(0xFFC8D5FF),
                primary = Color(0xFFAFC2FF),
                onPrimary = Color(0xFF102B78),
                background = Color(0xFF171A21),
                surface = Color(0xFF1D212A),
                surfaceContainer = Color(0xFF242935),
                surfaceContainerLow = Color(0xFF1D212A),
                surfaceContainerHigh = Color(0xFF2A303D),
                onSurface = Color(0xFFF0F1F5),
                onSurfaceVariant = Color(0xFFB6BECC),
                outlineVariant = Color(0xFF363D4B),
            )
        else
            lightColorScheme(
                secondaryContainer = Color(0xFFDFE4FF),
                onSecondaryContainer = Color(0xFF315CE7),
                primary = Color(0xFF315CE7),
                onPrimary = Color.White,
                primaryContainer = Color(0xFFDFE4FF),
                onPrimaryContainer = Color(0xFF173469),
                background = Color(0xFFFAF9F6),
                surface = Color.White,
                surfaceContainer = Color(0xFFEEEDE8),
                surfaceContainerLow = Color(0xFFF3F2EE),
                surfaceContainerHigh = Color(0xFFE9E8E3),
                onSurface = Color(0xFF202634),
                onSurfaceVariant = Color(0xFF5D6575),
                outlineVariant = Color(0xFFDFE1E7),
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
                        fontSize = 28.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = (-0.7).sp,
                    ),
                titleLarge = base.titleLarge.copy(fontSize = 22.sp, fontWeight = FontWeight.Bold),
                titleMedium =
                    base.titleMedium.copy(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                bodyLarge = base.bodyLarge.copy(fontSize = 16.sp, lineHeight = 24.sp),
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
