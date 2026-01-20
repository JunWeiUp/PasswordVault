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
  // 备份专用的固定盐值，确保跨平台只要主密码一致，派生的备份密钥就一致
  static final List<int> _backupSalt = utf8.encode('SecurePass_Backup_Standard_Salt_2024');

  static Future<bool> exportToJson(
    List<VaultItem> items, {
    String? masterPassword,
    EncryptionService? encryptionService,
  }) async {
    try {
      final Map<String, dynamic> itemsData = {
        'items': items.map((e) => e.toJson()).toList(),
      };
      
      String? payload;
      bool isEncrypted = false;

      if (masterPassword != null && encryptionService != null) {
        // 使用极简方案：直接对主密码进行 SHA-256 哈希作为密钥
        final backupKey = await encryptionService.deriveKeySimple(masterPassword.trim());

        final jsonString = jsonEncode(itemsData);
        final encryptedBytes = await encryptionService.encrypt(jsonString, backupKey);
        payload = base64.encode(encryptedBytes);
        isEncrypted = true;
      }

      final Map<String, dynamic> exportData = {
        'metadata': {
          'version': isEncrypted ? '3.0.0' : '1.0.0', // 3.0.0 使用 SHA-256 极简方案
          'exportDate': DateTime.now().toIso8601String(),
          'source': 'SecurePass',
          'itemCount': items.length,
          'encrypted': isEncrypted,
          if (isEncrypted) ...{
            'scheme': 'sha256_simple',
          },
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
          final String version = metadata?['version']?.toString() ?? '1.0.0';

          if (isEncrypted) {
            final String? payloadBase64 = data['payload'] as String?;
            if (payloadBase64 == null) throw Exception('加密备份缺少数据负载');

            if (encryptionService == null || masterPassword == null) {
              throw Exception('解密失败：该备份已加密，需要主密码才能导入');
            }

            final encryptedBytes = base64.decode(payloadBase64.replaceAll(RegExp(r'\s+'), ''));
            String decryptedJson = '';
            bool success = false;

            // 1. 优先尝试版本 3.0.0+ 的 SHA-256 极简方案
            try {
              final backupKey = await encryptionService.deriveKeySimple(masterPassword.trim());
              decryptedJson = await encryptionService.decrypt(encryptedBytes, backupKey);
              success = true;
              debugPrint('✅ 使用 SHA-256 极简方案解密成功');
            } catch (e) {
              debugPrint('⚠️ SHA-256 极简方案解密失败，尝试兼容性回退...');
            }

            // 2. 尝试版本 2.0.0 的固定盐值方案
            if (!success) {
              try {
                final backupKey = await encryptionService.deriveKey(
                  masterPassword.trim(), 
                  _backupSalt,
                  iterations: 2,
                  memory: 32 * 1024,
                  parallelism: 1,
                );
                decryptedJson = await encryptionService.decrypt(encryptedBytes, backupKey);
                success = true;
                debugPrint('✅ 使用标准固定盐值方案解密成功');
              } catch (_) {}
            }

            // 3. 兼容性回退：尝试使用备份中自带的 salt (1.2.x 方案)
            if (!success) {
              final String? backupSaltBase64 = metadata?['salt'] as String?;
              if (backupSaltBase64 != null) {
                try {
                  final salt = base64.decode(backupSaltBase64.trim());
                  final iters = metadata?['argon2_iterations'] ?? 2;
                  final mem = metadata?['argon2_memory'] ?? 32768;
                  
                  final legacyKey = await encryptionService.deriveKey(
                    masterPassword.trim(), 
                    salt,
                    iterations: iters,
                    memory: mem,
                  );
                  decryptedJson = await encryptionService.decrypt(encryptedBytes, legacyKey);
                  success = true;
                  debugPrint('✅ 使用备份自带盐值解密成功');
                } catch (_) {}
              }
            }

            // 3. 最终回退：尝试当前设备的本地 masterKey (旧版方案)
            if (!success && masterKey != null) {
              try {
                decryptedJson = await encryptionService.decrypt(encryptedBytes, masterKey);
                success = true;
                debugPrint('✅ 使用本地主密钥解密成功');
              } catch (_) {}
            }

            if (!success) {
              throw Exception('解密失败：主密码错误或备份文件已损坏 (MAC 不匹配)');
            }
            
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
          // 兼容更旧格式
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
