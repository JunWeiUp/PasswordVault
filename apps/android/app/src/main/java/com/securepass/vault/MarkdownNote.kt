package com.securepass.vault

import android.content.Intent
import android.net.Uri
import android.widget.TextView
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.AbstractMarkwonPlugin
import io.noties.markwon.Markwon
import io.noties.markwon.MarkwonConfiguration

@Composable
fun MarkdownNote(text: String) {
    val context = LocalContext.current
    val renderer =
        remember(context) {
            Markwon.builder(context)
                .usePlugin(
                    object : AbstractMarkwonPlugin() {
                        override fun configureConfiguration(builder: MarkwonConfiguration.Builder) {
                            builder.linkResolver { _, link ->
                                val uri = Uri.parse(link)
                                if (
                                    uri.scheme in listOf("http", "https") &&
                                        !uri.host.isNullOrBlank()
                                )
                                    runCatching {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, uri))
                                    }
                            }
                        }
                    }
                )
                .build()
        }
    val color = MaterialTheme.colorScheme.onSurface.toArgb()
    AndroidView(
        modifier = Modifier.fillMaxWidth(),
        factory = {
            TextView(it).apply {
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 16f)
                setTextIsSelectable(true)
                setLineSpacing(6f, 1f)
            }
        },
        update = { view ->
            view.setTextColor(color)
            renderer.setMarkdown(view, text)
        },
    )
}
