/// Web 等无 `dart:io` 的平台：不解析二维码。
Future<String?> decodeQrFromImageFile({String? path, List<int>? bytes}) async => null;
