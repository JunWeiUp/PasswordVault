package com.securepass.vault

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
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
    var optionsOpen by remember { mutableStateOf(false) }
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
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Button(modifier = Modifier.fillMaxWidth(), enabled = enabled, onClick = { optionsOpen = true }) {
            Text(t("扫描或导入验证码", "Scan or import authenticator code"))
        }
        Text(t("也可在下方手动输入密钥。相机画面只在本机处理。", "You can also enter the secret below. Camera images are processed only on this device."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    if (optionsOpen) VaultActionSheet(t("添加验证码", "Add authenticator code"),
        t("扫描网站提供的二维码，或手动输入密钥。", "Scan the QR code provided by the website or enter the secret manually."),
        { optionsOpen = false }) {
        Button(modifier = Modifier.fillMaxWidth(), enabled = enabled, onClick = { optionsOpen = false; cameraOpen = true }) { Text(t("扫描二维码", "Scan QR code")) }
        OutlinedButton(modifier = Modifier.fillMaxWidth(), enabled = enabled, onClick = { optionsOpen = false }) { Text(t("手动输入密钥", "Enter secret manually")) }
        OutlinedButton(modifier = Modifier.fillMaxWidth(), enabled = enabled, onClick = { optionsOpen = false; photo.launch(arrayOf("image/*")) }) { Text(t("从图片识别", "Read from image")) }
        Text(t("拒绝相机权限时仍可手动输入。扫描和图片识别不会直接保存，请核对后再添加。", "You can enter the secret if camera permission is denied. Review scanned or imported details before saving."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { TextButton(onClick = { optionsOpen = false }) { Text(t("取消", "Cancel")) } }
    }
}
