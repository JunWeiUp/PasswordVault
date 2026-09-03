import 'dart:convert';
import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';

Future<bool> saveJsonFileImpl(String jsonString, String fileName) async {
  try {
    final bytes = utf8.encode(jsonString);
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.document.createElement('a') as html.AnchorElement
      ..href = url
      ..style.display = 'none'
      ..download = fileName;

    html.document.body!.children.add(anchor);
    anchor.click();
    html.document.body!.children.remove(anchor);
    html.Url.revokeObjectUrl(url);
    return true;
  } catch (e) {
    return false;
  }
}

Future<bool> saveCsvFileImpl(String csvString, String fileName) async {
  try {
    final bytes = utf8.encode(csvString);
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.document.createElement('a') as html.AnchorElement
      ..href = url
      ..style.display = 'none'
      ..download = fileName;

    html.document.body!.children.add(anchor);
    anchor.click();
    html.document.body!.children.remove(anchor);
    html.Url.revokeObjectUrl(url);
    return true;
  } catch (e) {
    return false;
  }
}

Future<String?> pickJsonFileImpl() async {
  return _pickFileImpl(['json']);
}

Future<String?> pickCsvFileImpl() async {
  return _pickFileImpl(['csv']);
}

Future<String?> pickCsvOrEncFileImpl() async {
  return _pickFileImpl(['csv', 'enc']);
}

Future<String?> _pickFileImpl(List<String> extensions) async {
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: extensions,
    allowMultiple: false,
  );

  if (result != null && result.files.single.bytes != null) {
    return utf8.decode(result.files.single.bytes!);
  }
  return null;
}
