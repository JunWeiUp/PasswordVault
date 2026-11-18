package com.securepass.vault

import android.content.Context
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.webkit.WebView
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.platform.InterceptPlatformTextInput
import androidx.compose.ui.platform.PlatformTextInputMethodRequest

/** Adds `IME_FLAG_NO_PERSONALIZED_LEARNING`; Compose has no KeyboardOptions flag for it. */
internal fun withoutPersonalizedLearning(imeOptions: Int): Int = imeOptions or EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING

/**
 * Asks every Compose text field below it (passwords, secrets, notes, search) to keep typed text out
 * of the keyboard's personalized learning. Always on; the IME may still ignore the request.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun NoPersonalizedLearning(content: @Composable () -> Unit) {
    InterceptPlatformTextInput(
        interceptor = { request, nextHandler ->
            val private = object : PlatformTextInputMethodRequest {
                override fun createInputConnection(outAttributes: EditorInfo): InputConnection {
                    val connection = request.createInputConnection(outAttributes)
                    outAttributes.imeOptions = withoutPersonalizedLearning(outAttributes.imeOptions)
                    return connection
                }
            }
            nextHandler.startInputMethod(private)
        },
        content = content,
    )
}

/** WebView for the rich note editor that makes the same IME request as Compose fields. */
internal class PrivateInputWebView(context: Context) : WebView(context) {
    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection? {
        val connection = super.onCreateInputConnection(outAttrs)
        outAttrs.imeOptions = withoutPersonalizedLearning(outAttrs.imeOptions)
        return connection
    }
}

/** `setContent` with [NoPersonalizedLearning] applied to the whole window. */
internal fun androidx.activity.ComponentActivity.setPrivateContent(content: @Composable () -> Unit) {
    setContent { NoPersonalizedLearning(content) }
}
