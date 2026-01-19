import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../features/vault/domain/models/vault_item.dart';
import 'file_utils.dart';

class ImportExportHelper {
  static Future<bool> exportToJson(List<VaultItem> items) async {
    try {
      final Map<String, dynamic> exportData = {
        'metadata': {
          'version': '1.0.0',
          'exportDate': DateTime.now().toIso8601String(),
          'source': 'SecurePass',
          'itemCount': items.length,
        },
        'items': items.map((e) => e.toJson()).toList(),
      };
      
      final String jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      final String fileName = kIsWeb 
          ? 'securepass_backup.json' 
          : 'securepass_backup_${DateTime.now().millisecondsSinceEpoch}.json';

      return await FileUtils.saveJsonFile(jsonString, fileName);
    } catch (e) {
      debugPrint('Export failed: $e');
      return false;
    }
  }

  static Future<List<VaultItem>?> importFromJson() async {
    try {
      final String? content = await FileUtils.pickJsonFile();

      if (content != null) {
        final dynamic data = jsonDecode(content);
        
        if (data is Map<String, dynamic> && data.containsKey('items') && data['items'] is List) {
          final List<dynamic> itemsList = data['items'];
          return itemsList.map((e) => VaultItem.fromJson(e as Map<String, dynamic>)).toList();
        } else if (data is List) {
          // 兼容旧格式（直接是列表）
          return data.map((e) => VaultItem.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
      return null;
    } catch (e) {
      debugPrint('Import failed: $e');
      return null;
    }
  }
}
