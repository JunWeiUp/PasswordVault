import 'dart:io';

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:path_provider/path_provider.dart';

/// 使用 ML Kit 从本地图片解析首个 QR 内容（仅 Android / iOS）。
Future<String?> decodeQrFromImageFile({String? path, List<int>? bytes}) async {
  if (!Platform.isAndroid && !Platform.isIOS) return null;

  String? filePath = path;
  if ((filePath == null || filePath.isEmpty) && bytes != null && bytes.isNotEmpty) {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/qr_pick_${DateTime.now().millisecondsSinceEpoch}.bin');
    await f.writeAsBytes(bytes, flush: true);
    filePath = f.path;
  }
  if (filePath == null || filePath.isEmpty) return null;

  final input = InputImage.fromFilePath(filePath);
  final scanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);
  try {
    final barcodes = await scanner.processImage(input);
    for (final b in barcodes) {
      final v = b.rawValue;
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  } finally {
    await scanner.close();
  }
}
