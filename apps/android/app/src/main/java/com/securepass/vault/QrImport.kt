package com.securepass.vault

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun QrImport(
    vault: VaultRepository,
    t: (String, String) -> String,
    result: (String) -> Unit,
    error: () -> Unit,
) {
    val enabled = LocalEditorEnabled.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    fun scan(bitmap: Bitmap?) {
        if (bitmap == null) return
        scope.launch {
            try {
                val uri =
                    withContext(Dispatchers.Default) {
                        val pixels = IntArray(bitmap.width * bitmap.height)
                        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
                        val source = RGBLuminanceSource(bitmap.width, bitmap.height, pixels)
                        MultiFormatReader()
                            .decode(
                                BinaryBitmap(HybridBinarizer(source)),
                                mapOf(
                                    DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)
                                ),
                            )
                            .text
                    }
                require(uri.startsWith("otpauth://", true))
                result(uri)
            } catch (_: Exception) {
                error()
            } finally {
                bitmap.recycle()
            }
        }
    }
    val photo =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            vault.systemFileFlow = false
            if (uri != null)
                scope.launch {
                    try {
                        val bitmap =
                            withContext(Dispatchers.IO) {
                                val bounds =
                                    BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                context.contentResolver.openInputStream(uri)?.use {
                                    BitmapFactory.decodeStream(it, null, bounds)
                                }
                                require(bounds.outWidth > 0 && bounds.outHeight > 0)
                                var sample = 1
                                while (
                                    maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048
                                ) sample *= 2
                                context.contentResolver.openInputStream(uri)?.use {
                                    BitmapFactory.decodeStream(
                                        it,
                                        null,
                                        BitmapFactory.Options().apply { inSampleSize = sample },
                                    )
                                }
                            }
                        scan(bitmap)
                    } catch (_: Exception) {
                        error()
                    }
                }
        }
    var cameraOpen by remember { mutableStateOf(false) }
    if (cameraOpen)
        LiveQrScanner(
            vault,
            t,
            { uri ->
                cameraOpen = false
                result(uri)
            },
            { cameraOpen = false },
        )
    Row {
        TextButton(
            enabled = enabled,
            onClick = {
                vault.systemFileFlow = true
                photo.launch(arrayOf("image/*"))
            },
        ) {
            Text(t("导入二维码图片", "Import QR image"))
        }
        TextButton(enabled = enabled, onClick = { cameraOpen = true }) {
            Text(t("扫描二维码", "Scan QR"))
        }
    }
}
