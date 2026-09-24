package com.securepass.vault

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.Observer
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.launch
import org.json.JSONObject

internal fun decodeQrLuma(bytes: ByteArray, width: Int, height: Int): String? =
    try {
        val source = PlanarYUVLuminanceSource(bytes, width, height, 0, 0, width, height, false)
        MultiFormatReader()
            .decode(
                BinaryBitmap(HybridBinarizer(source)),
                mapOf(DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE)),
            )
            .text
    } catch (_: ReaderException) {
        null
    }

@Composable
internal fun LiveQrScanner(
    vault: VaultRepository,
    t: (String, String) -> String,
    result: (String) -> Unit,
    close: () -> Unit,
) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    var message by remember { mutableStateOf<String?>(null) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var torch by remember { mutableStateOf(false) }
    val preview = remember {
        PreviewView(context).apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        }
    }
    val permission =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
            granted = it
        }
    val currentResult by rememberUpdatedState(result)
    val active = remember(granted, owner) { AtomicBoolean(true) }
    val session = remember(granted, owner) { QrScanSession() }
    val scope = rememberCoroutineScope()
    fun dismiss() {
        active.set(false)
        session.close()
        close()
    }
    LaunchedEffect(Unit) { if (!granted) permission.launch(Manifest.permission.CAMERA) }
    DisposableEffect(granted, owner) {
        if (owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) session.resume()
        val lifecycle = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) session.resume()
            else if (
                event == Lifecycle.Event.ON_PAUSE ||
                    event == Lifecycle.Event.ON_STOP ||
                    event == Lifecycle.Event.ON_DESTROY
            )
                session.pause()
        }
        owner.lifecycle.addObserver(lifecycle)
        val main = ContextCompat.getMainExecutor(context)
        val executor = Executors.newSingleThreadExecutor()
        var provider: ProcessCameraProvider? = null
        var bound: Camera? = null
        val observer =
            Observer<CameraState> { state ->
                if (active.get()) {
                    if (state.error != null)
                        message =
                            t(
                                "相机暂不可用，可关闭后导入二维码图片。",
                                "Camera unavailable. Close and import a QR image instead.",
                            )
                    else if (state.type == CameraState.Type.OPEN) message = t("正在扫描", "Scanning")
                }
            }
        val view = Preview.Builder().build()
        val analysis =
            ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
        if (granted) {
            val future = ProcessCameraProvider.getInstance(context)
            future.addListener(
                {
                    if (active.get())
                        try {
                            provider = future.get()
                            val selector =
                                if (provider!!.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA))
                                    CameraSelector.DEFAULT_BACK_CAMERA
                                else CameraSelector.DEFAULT_FRONT_CAMERA
                            view.setSurfaceProvider(preview.surfaceProvider)
                            analysis.setAnalyzer(executor) { image ->
                                try {
                                    if (active.get() && session.canScan()) {
                                        val plane = image.planes[0]
                                        val buffer = plane.buffer.duplicate()
                                        val offset = buffer.position()
                                        val luma = ByteArray(image.width * image.height)
                                        try {
                                            for (y in 0 until image.height) for (x in
                                                0 until image.width) luma[y * image.width + x] =
                                                buffer.get(
                                                    offset +
                                                        y * plane.rowStride +
                                                        x * plane.pixelStride
                                                )
                                            val uri = decodeQrLuma(luma, image.width, image.height)
                                            if (uri != null) {
                                                val token = session.begin()
                                                if (token != null)
                                                    main.execute {
                                                        if (session.owns(token))
                                                            scope.launch {
                                                                try {
                                                                    vault.command(
                                                                        "parse-totp",
                                                                        JSONObject().put("uri", uri),
                                                                    )
                                                                    if (session.accept(token))
                                                                        currentResult(uri)
                                                                } catch (
                                                                    cancelled:
                                                                        kotlinx.coroutines.CancellationException) {
                                                                    throw cancelled
                                                                } catch (_: Exception) {
                                                                    if (session.owns(token))
                                                                        message =
                                                                            t(
                                                                                "二维码设置无效或不支持，请继续扫描。",
                                                                                "Invalid or unsupported setup QR. Keep scanning.",
                                                                            )
                                                                } finally {
                                                                    session.reject(token)
                                                                }
                                                            }
                                                    }
                                            }
                                        } finally {
                                            luma.fill(0)
                                        }
                                    }
                                } catch (_: Exception) {
                                    /* Skip malformed/unavailable frames; keep the camera usable. */
                                } finally {
                                    image.close()
                                }
                            }
                            camera = provider!!.bindToLifecycle(owner, selector, view, analysis)
                            bound = camera
                            bound?.cameraInfo?.cameraState?.observe(owner, observer)
                        } catch (_: Exception) {
                            message =
                                t(
                                    "相机暂不可用，可关闭后导入二维码图片。",
                                    "Camera unavailable. Close and import a QR image instead.",
                                )
                        }
                },
                main,
            )
        }
        onDispose {
            active.set(false)
            session.close()
            owner.lifecycle.removeObserver(lifecycle)
            bound?.cameraInfo?.cameraState?.removeObserver(observer)
            analysis.clearAnalyzer()
            provider?.unbind(view, analysis)
            camera = null
            executor.shutdown()
        }
    }
    Dialog(
        onDismissRequest = ::dismiss,
        properties =
            DialogProperties(
                usePlatformDefaultWidth = false,
                securePolicy = androidx.compose.ui.window.SecureFlagPolicy.Inherit,
            ),
    ) {
        Surface(Modifier.fillMaxSize()) {
            Column(
                Modifier.fillMaxSize().padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Row {
                    Text(
                        t("扫描验证码", "Scan authenticator QR"),
                        Modifier.weight(1f),
                        style = MaterialTheme.typography.titleLarge,
                    )
                    TextButton(onClick = ::dismiss) { Text(t("关闭", "Close")) }
                }
                Text(t("对准二维码，识别后会自动填入。", "Point at a QR code to fill the setup automatically."))
                if (granted)
                    AndroidView(
                        factory = { preview },
                        modifier = Modifier.weight(1f).fillMaxWidth(),
                    )
                else {
                    Text(
                        t(
                            "需要相机权限；也可以关闭后导入图片。",
                            "Camera permission is needed; you can also close and import an image.",
                        )
                    )
                    TextButton(onClick = { permission.launch(Manifest.permission.CAMERA) }) {
                        Text(t("允许使用相机", "Allow camera"))
                    }
                }
                message?.let { Text(it) }
                if (camera?.cameraInfo?.hasFlashUnit() == true)
                    TextButton(
                        onClick = {
                            torch = !torch
                            camera?.cameraControl?.enableTorch(torch)
                        }
                    ) {
                        Text(if (torch) t("关闭补光", "Flash off") else t("打开补光", "Flash on"))
                    }
            }
        }
    }
}
