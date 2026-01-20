import '../../features/vault/domain/models/vault_item.dart';
import 'file_utils_stub.dart'
    if (dart.library.io) 'file_utils_io.dart'
    if (dart.library.html) 'file_utils_web.dart';

abstract class FileUtils {
  static Future<bool> saveJsonFile(String jsonString, String fileName) =>
      saveJsonFileImpl(jsonString, fileName);

  static Future<String?> pickJsonFile() => pickJsonFileImpl();

  static Future<String?> pickCsvFile() => pickCsvFileImpl();
}
