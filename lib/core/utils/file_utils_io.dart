import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<bool> saveJsonFileImpl(String jsonString, String fileName) async {
  if (Platform.isAndroid || Platform.isIOS) {
    // 移动端：先存入临时目录，然后调用分享对话框
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$fileName');
    await file.writeAsString(jsonString);
    
    final result = await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'SecurePass 数据备份',
    );
    
    return result.status == ShareResultStatus.success;
  } else {
    // Desktop 平台
    String? outputPath = await FilePicker.platform.saveFile(
      dialogTitle: '选择导出位置',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (outputPath != null) {
      final File file = File(outputPath);
      await file.writeAsString(jsonString);
      return true;
    }
  }
  return false;
}

Future<String?> pickJsonFileImpl() async {
  return _pickFileImpl(['json']);
}

Future<String?> pickCsvFileImpl() async {
  return _pickFileImpl(['csv']);
}

Future<String?> _pickFileImpl(List<String> extensions) async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: extensions,
    allowMultiple: false,
  );

  if (result != null && result.files.single.path != null) {
    final File file = File(result.files.single.path!);
    return await file.readAsString();
  }
  return null;
}
