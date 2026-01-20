import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:csv/csv.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../features/vault/domain/models/vault_item.dart';
import '../security/encryption_service.dart';
import 'file_utils.dart';

class ImportExportHelper {
  static Future<bool> exportToJson(List<VaultItem> items, {SecretKey? masterKey, EncryptionService? encryptionService}) async {
    try {
      final Map<String, dynamic> itemsData = {
        'items': items.map((e) => e.toJson()).toList(),
      };
      
      String? payload;
      bool isEncrypted = false;
      String? saltBase64;

      if (masterKey != null && encryptionService != null) {
        final jsonString = jsonEncode(itemsData);
        final encryptedBytes = await encryptionService.encrypt(jsonString, masterKey);
        payload = base64Encode(encryptedBytes);
        isEncrypted = true;

        // 获取当前使用的 salt，并包含在备份中
        final prefs = await SharedPreferences.getInstance();
        saltBase64 = prefs.getString('master_key_salt');
      }

      final Map<String, dynamic> exportData = {
        'metadata': {
          'version': isEncrypted ? '1.2.0' : '1.0.0', // 1.2.0 包含了 salt
          'exportDate': DateTime.now().toIso8601String(),
          'source': 'SecurePass',
          'itemCount': items.length,
          'encrypted': isEncrypted,
          if (saltBase64 != null) 'salt': saltBase64,
        },
      };

      if (isEncrypted) {
        exportData['payload'] = payload;
      } else {
        exportData['items'] = itemsData['items'];
      }
      
      final String jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      final String fileName = kIsWeb 
          ? (isEncrypted ? 'securepass_backup_encrypted.json' : 'securepass_backup.json')
          : 'securepass_backup_${isEncrypted ? 'enc_' : ''}${DateTime.now().millisecondsSinceEpoch}.json';

      return await FileUtils.saveJsonFile(jsonString, fileName);
    } catch (e) {
      debugPrint('Export failed: $e');
      return false;
    }
  }

  static Future<List<VaultItem>?> importFromJson({
    SecretKey? masterKey, 
    String? masterPassword,
    EncryptionService? encryptionService,
  }) async {
    try {
      final String? content = await FileUtils.pickJsonFile();

      if (content != null) {
        final dynamic data = jsonDecode(content);
        
        if (data is Map<String, dynamic>) {
          final metadata = data['metadata'] as Map<String, dynamic>?;
          final bool isEncrypted = metadata?['encrypted'] ?? false;

          if (isEncrypted) {
            final String? payloadBase64 = data['payload'] as String?;
            if (payloadBase64 == null) throw Exception('加密备份缺少数据负载');

            if (encryptionService == null) {
              throw Exception('解密失败：缺少加密服务');
            }

            SecretKey? decryptionKey = masterKey;

            // 检查备份中的 salt 是否与本地不同
            final String? backupSaltBase64 = metadata?['salt'] as String?;
            if (backupSaltBase64 != null && masterPassword != null) {
              final prefs = await SharedPreferences.getInstance();
              final localSaltBase64 = prefs.getString('master_key_salt');
              
              if (backupSaltBase64 != localSaltBase64) {
                debugPrint('🔄 备份 salt 与本地不同，尝试重新派生临时密钥...');
                final backupSalt = base64Decode(backupSaltBase64);
                decryptionKey = await encryptionService.deriveKey(masterPassword, backupSalt);
              }
            }

            if (decryptionKey == null) {
              throw Exception('该备份已加密，需要主密码才能导入');
            }
            
            final encryptedBytes = base64Decode(payloadBase64);
            final decryptedJson = await encryptionService.decrypt(encryptedBytes, decryptionKey);
            final dynamic decryptedData = jsonDecode(decryptedJson);

            if (decryptedData is Map<String, dynamic> && decryptedData.containsKey('items')) {
              final List<dynamic> itemsList = decryptedData['items'];
              return itemsList.map((e) => VaultItem.fromJson(e as Map<String, dynamic>)).toList();
            }
          } else if (data.containsKey('items') && data['items'] is List) {
            final List<dynamic> itemsList = data['items'];
            return itemsList.map((e) => VaultItem.fromJson(e as Map<String, dynamic>)).toList();
          }
        } else if (data is List) {
          // 兼容旧格式（直接是列表）
          return data.map((e) => VaultItem.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
      return null;
    } catch (e) {
      debugPrint('Import failed: $e');
      rethrow;
    }
  }

  static Future<List<VaultItem>?> importFromLastPassCsv() async {
    try {
      final String? content = await FileUtils.pickCsvFile();
      if (content == null) return null;

      return parseLastPassCsv(content);
    } catch (e) {
      debugPrint('LastPass import failed: $e');
      rethrow;
    }
  }

  static List<VaultItem> parseLastPassCsv(String content) {
    // 尝试识别换行符
    String eol = '\n';
    if (content.contains('\r\n')) {
      eol = '\r\n';
    }

    // 使用 csv 库解析，自动处理引号、换行等复杂情况
    final List<List<dynamic>> rows = CsvToListConverter(
      shouldParseNumbers: false,
      eol: eol,
    ).convert(content);
    
    if (rows.isEmpty) return [];

    // LastPass 默认格式: url,username,password,extra,name,grouping,fav
    int urlIdx = 0, userIdx = 1, passIdx = 2, extraIdx = 3, nameIdx = 4, groupIdx = 5, favIdx = 6;
    
    // 检查是否有表头
    bool hasHeader = rows[0].any((cell) => cell.toString().toLowerCase() == 'url');
    int startRow = hasHeader ? 1 : 0;
    
    if (hasHeader) {
      final header = rows[0].map((e) => e.toString().toLowerCase()).toList();
      urlIdx = header.indexOf('url');
      userIdx = header.indexOf('username');
      passIdx = header.indexOf('password');
      extraIdx = header.indexOf('extra');
      nameIdx = header.indexOf('name');
      groupIdx = header.indexOf('grouping');
      favIdx = header.indexOf('fav');
    }

    final List<VaultItem> items = [];
    const uuid = Uuid();

    for (int i = startRow; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty || (row.length == 1 && row[0].toString().isEmpty)) continue;

      final String url = _safeGet(row, urlIdx);
      final String username = _safeGet(row, userIdx);
      final String password = _safeGet(row, passIdx);
      final String extra = _safeGet(row, extraIdx);
      final String name = _safeGet(row, nameIdx);
      final String grouping = _safeGet(row, groupIdx);
      final String fav = _safeGet(row, favIdx);

      items.add(VaultItem(
        id: uuid.v4(),
        type: VaultItemType.password,
        title: name.isNotEmpty ? name : (url.isNotEmpty ? url : '未命名导入'),
        username: username,
        password: password,
        url: url,
        note: extra,
        category: grouping.isNotEmpty ? grouping : 'LastPass 导入',
        isFavorite: fav == '1' || fav.toLowerCase() == 'true',
      ));
    }
    return items;
  }

  static String _safeGet(List<dynamic> row, int index) {
    if (index >= 0 && index < row.length) {
      return row[index]?.toString() ?? '';
    }
    return '';
  }
}
