import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
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

      if (masterKey != null && encryptionService != null) {
        final jsonString = jsonEncode(itemsData);
        final encryptedBytes = await encryptionService.encrypt(jsonString, masterKey);
        payload = base64Encode(encryptedBytes);
        isEncrypted = true;
      }

      final Map<String, dynamic> exportData = {
        'metadata': {
          'version': isEncrypted ? '1.1.0' : '1.0.0',
          'exportDate': DateTime.now().toIso8601String(),
          'source': 'SecurePass',
          'itemCount': items.length,
          'encrypted': isEncrypted,
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

  static Future<List<VaultItem>?> importFromJson({SecretKey? masterKey, EncryptionService? encryptionService}) async {
    try {
      final String? content = await FileUtils.pickJsonFile();

      if (content != null) {
        final dynamic data = jsonDecode(content);
        
        if (data is Map<String, dynamic>) {
          final metadata = data['metadata'] as Map<String, dynamic>?;
          final bool isEncrypted = metadata?['encrypted'] ?? false;

          if (isEncrypted) {
            if (masterKey == null || encryptionService == null) {
              throw Exception('该备份已加密，需要主密码才能导入');
            }
            
            final String? payloadBase64 = data['payload'] as String?;
            if (payloadBase64 == null) throw Exception('加密备份缺少数据负载');

            final encryptedBytes = base64Decode(payloadBase64);
            final decryptedJson = await encryptionService.decrypt(encryptedBytes, masterKey);
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
}
