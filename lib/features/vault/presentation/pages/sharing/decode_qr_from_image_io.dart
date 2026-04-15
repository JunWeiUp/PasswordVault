import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

/// 使用纯 Dart（zxing2）从本地图片解析首个 QR 内容，无 ML Kit 原生库。
Future<String?> decodeQrFromImageFile({String? path, List<int>? bytes}) async {
  late Uint8List data;
  if (bytes != null && bytes.isNotEmpty) {
    data = Uint8List.fromList(bytes);
  } else if (path != null && path.isNotEmpty) {
    data = await File(path).readAsBytes();
  } else {
    return null;
  }

  final image = img.decodeImage(data);
  if (image == null) return null;

  final rgba = image.convert(numChannels: 4);
  final source = RGBLuminanceSource(
    rgba.width,
    rgba.height,
    rgba.getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
  );

  for (final makeBinarizer in [
    () => GlobalHistogramBinarizer(source),
    () => HybridBinarizer(source),
  ]) {
    try {
      final bitmap = BinaryBitmap(makeBinarizer());
      final result = QRCodeReader().decode(bitmap);
      final text = result.text;
      if (text.trim().isNotEmpty) return text.trim();
    } catch (_) {
      continue;
    }
  }
  return null;
}
