import 'package:password/core/l10n/l10n.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';
import 'package:csv/csv.dart';
import 'package:uuid/uuid.dart';
import '../../features/vault/domain/models/vault_item.dart';
import '../security/encryption_service.dart';
import 'file_utils.dart';

class ImportExportHelper {
  // 备份专用的固定盐值，确保跨平台只要主密码一致，派生的备份密钥就一致
  static final List<int> _backupSalt = utf8.encode(
    'SecurePass_Backup_Standard_Salt_2024',
  );

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
        final backupKey = await encryptionService.deriveKeySimple(
          masterPassword.trim(),
        );

        final jsonString = jsonEncode(itemsData);
        final encryptedBytes = await encryptionService.encrypt(
          jsonString,
          backupKey,
        );
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
          if (isEncrypted) ...{'scheme': 'sha256_simple'},
        },
      };

      if (isEncrypted) {
        exportData['payload'] = payload;
      } else {
        exportData['items'] = itemsData['items'];
      }

      final String jsonString = const JsonEncoder.withIndent(
        '  ',
      ).convert(exportData);
      final String fileName = kIsWeb
          ? (isEncrypted
                ? 'securepass_backup_encrypted.json'
                : 'securepass_backup.json')
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
          // version reserved for future migration logic
          final _ = metadata?['version']?.toString() ?? '1.0.0';

          if (isEncrypted) {
            final String? payloadBase64 = data['payload'] as String?;
            if (payloadBase64 == null)
              throw Exception(tr.theEncryptedBackupHasNoPayload);

            if (encryptionService == null || masterPassword == null) {
              throw Exception(tr.enterTheMasterPasswordToImportThis);
            }

            final encryptedBytes = base64.decode(
              payloadBase64.replaceAll(RegExp(r'\s+'), ''),
            );
            String decryptedJson = '';
            bool success = false;

            // 1. 优先尝试版本 3.0.0+ 的 SHA-256 极简方案
            try {
              final backupKey = await encryptionService.deriveKeySimple(
                masterPassword.trim(),
              );
              decryptedJson = await encryptionService.decrypt(
                encryptedBytes,
                backupKey,
              );
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
                decryptedJson = await encryptionService.decrypt(
                  encryptedBytes,
                  backupKey,
                );
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
                  decryptedJson = await encryptionService.decrypt(
                    encryptedBytes,
                    legacyKey,
                  );
                  success = true;
                  debugPrint('✅ 使用备份自带盐值解密成功');
                } catch (_) {}
              }
            }

            // 3. 最终回退：尝试当前设备的本地 masterKey (旧版方案)
            if (!success && masterKey != null) {
              try {
                decryptedJson = await encryptionService.decrypt(
                  encryptedBytes,
                  masterKey,
                );
                success = true;
                debugPrint('✅ 使用本地主密钥解密成功');
              } catch (_) {}
            }

            if (!success) {
              throw Exception(
                tr.decryptionFailedIncorrectMasterPasswordOrDamaged,
              );
            }

            final dynamic decryptedData = jsonDecode(decryptedJson);
            if (decryptedData is Map<String, dynamic> &&
                decryptedData.containsKey('items')) {
              final List<dynamic> itemsList = decryptedData['items'];
              return itemsList
                  .map((e) => VaultItem.fromJson(e as Map<String, dynamic>))
                  .toList();
            }
          } else if (data.containsKey('items') && data['items'] is List) {
            final List<dynamic> itemsList = data['items'];
            return itemsList
                .map((e) => VaultItem.fromJson(e as Map<String, dynamic>))
                .toList();
          }
        } else if (data is List) {
          // 兼容更旧格式
          return data
              .map((e) => VaultItem.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
      return null;
    } catch (e) {
      debugPrint('Import failed: $e');
      rethrow;
    }
  }

  static Future<bool> exportToCsv(
    List<VaultItem> items, {
    String? masterPassword,
    EncryptionService? encryptionService,
    bool encrypted = false,
  }) async {
    try {
      final headers = [
        'type',
        'title',
        'username',
        'password',
        'secret',
        'period',
        'url',
        'note',
        'category',
        'email',
        'network',
        'address',
        'privateKey',
        'mnemonic',
      ];

      final rows = <List<dynamic>>[
        headers,
        ...items.map((item) {
          return [
            item.type.name,
            item.title,
            item.username,
            item.password ?? '',
            item.secret ?? '',
            item.period.toString(),
            item.url ?? '',
            item.note ?? '',
            item.category ?? '',
            item.email ?? '',
            item.network ?? '',
            item.address ?? '',
            item.privateKey ?? '',
            item.mnemonic ?? '',
          ];
        }),
      ];

      final csvString = const ListToCsvConverter().convert(rows);
      if (!encrypted) {
        final fileName = kIsWeb
            ? 'securepass_export.csv'
            : 'securepass_export_${DateTime.now().millisecondsSinceEpoch}.csv';
        return await FileUtils.saveCsvFile(csvString, fileName);
      }

      if (masterPassword == null || encryptionService == null) {
        throw Exception(tr.aMasterPasswordIsRequiredForEncrypted);
      }

      final backupKey = await encryptionService.deriveKeySimple(
        masterPassword.trim(),
      );
      final encryptedBytes = await encryptionService.encrypt(
        csvString,
        backupKey,
      );
      final payload = base64.encode(encryptedBytes);

      final fileName = kIsWeb
          ? 'securepass_export_encrypted.csv.enc'
          : 'securepass_export_enc_${DateTime.now().millisecondsSinceEpoch}.csv.enc';

      return await FileUtils.saveCsvFile(payload, fileName);
    } catch (e) {
      debugPrint('CSV export failed: $e');
      return false;
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
    int urlIdx = 0,
        userIdx = 1,
        passIdx = 2,
        extraIdx = 3,
        nameIdx = 4,
        groupIdx = 5,
        favIdx = 6;

    // 检查是否有表头
    bool hasHeader = rows[0].any(
      (cell) => cell.toString().toLowerCase() == 'url',
    );
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
      if (row.isEmpty || (row.length == 1 && row[0].toString().isEmpty))
        continue;

      final String url = _safeGet(row, urlIdx);
      final String username = _safeGet(row, userIdx);
      final String password = _safeGet(row, passIdx);
      final String extra = _safeGet(row, extraIdx);
      final String name = _safeGet(row, nameIdx);
      final String grouping = _safeGet(row, groupIdx);
      final String fav = _safeGet(row, favIdx);

      items.add(
        VaultItem(
          id: uuid.v4(),
          type: VaultItemType.password,
          title: name.isNotEmpty
              ? name
              : (url.isNotEmpty ? url : tr.untitledImport),
          username: username,
          password: password,
          url: url,
          note: extra,
          category: grouping.isNotEmpty ? grouping : tr.lastpassImport,
          isFavorite: fav == '1' || fav.toLowerCase() == 'true',
        ),
      );
    }
    return items;
  }

  static Future<List<VaultItem>?> importFromEncryptedCsv({
    required String masterPassword,
    required EncryptionService encryptionService,
  }) async {
    try {
      final content = await FileUtils.pickCsvOrEncFile();
      if (content == null) return null;

      final encryptedBytes = base64.decode(
        content.replaceAll(RegExp(r'\s+'), ''),
      );
      final backupKey = await encryptionService.deriveKeySimple(
        masterPassword.trim(),
      );
      final decryptedCsv = await encryptionService.decrypt(
        encryptedBytes,
        backupKey,
      );

      return parseSecurePassCsv(decryptedCsv);
    } catch (e) {
      debugPrint('Encrypted CSV import failed: $e');
      rethrow;
    }
  }

  static Future<List<VaultItem>?> importFromBitwardenCsv() async {
    try {
      final content = await FileUtils.pickCsvFile();
      if (content == null) return null;
      return parseBitwardenCsv(content);
    } catch (e) {
      debugPrint('Bitwarden import failed: $e');
      rethrow;
    }
  }

  static Future<List<VaultItem>?> importFrom1PasswordCsv() async {
    try {
      final content = await FileUtils.pickCsvFile();
      if (content == null) return null;
      return parse1PasswordCsv(content);
    } catch (e) {
      debugPrint('1Password import failed: $e');
      rethrow;
    }
  }

  static Future<List<VaultItem>?> importFromChromeCsv() async {
    try {
      final content = await FileUtils.pickCsvFile();
      if (content == null) return null;
      return parseChromeCsv(content);
    } catch (e) {
      debugPrint('Chrome import failed: $e');
      rethrow;
    }
  }

  static List<VaultItem> parseBitwardenCsv(String content) {
    final rows = _parseCsvRows(content);
    if (rows.isEmpty) return [];

    const uuid = Uuid();
    final items = <VaultItem>[];

    for (final row in rows) {
      final type = _valueFor(row, ['type']);
      if (type.isNotEmpty && type.toLowerCase() != 'login') continue;

      final name = _valueFor(row, ['name']);
      final username = _valueFor(row, ['login_username', 'username']);
      final password = _valueFor(row, ['login_password', 'password']);
      final url = _valueFor(row, ['login_uri', 'uri', 'url']);
      final notes = _valueFor(row, ['notes', 'note']);
      final folder = _valueFor(row, ['folder', 'group']);

      if (_isBlank(name) &&
          _isBlank(username) &&
          _isBlank(password) &&
          _isBlank(url)) {
        continue;
      }

      items.add(
        VaultItem(
          id: uuid.v4(),
          type: VaultItemType.password,
          title: name.isNotEmpty
              ? name
              : (url.isNotEmpty ? url : tr.bitwardenImport),
          username: username,
          password: password.isEmpty ? null : password,
          url: url.isEmpty ? null : url,
          note: notes.isEmpty ? null : notes,
          category: folder.isNotEmpty ? folder : tr.bitwardenImport,
        ),
      );
    }

    return items;
  }

  static List<VaultItem> parse1PasswordCsv(String content) {
    final rows = _parseCsvRows(content);
    if (rows.isEmpty) return [];

    const uuid = Uuid();
    final items = <VaultItem>[];

    for (final row in rows) {
      final title = _valueFor(row, ['title', 'name']);
      final username = _valueFor(row, ['username', 'login']);
      final password = _valueFor(row, ['password']);
      final url = _valueFor(row, ['url', 'website', 'website url']);
      final notes = _valueFor(row, ['notes', 'note']);
      final category = _valueFor(row, ['category', 'vault']);

      if (_isBlank(title) &&
          _isBlank(username) &&
          _isBlank(password) &&
          _isBlank(url)) {
        continue;
      }

      items.add(
        VaultItem(
          id: uuid.v4(),
          type: VaultItemType.password,
          title: title.isNotEmpty
              ? title
              : (url.isNotEmpty ? url : tr.passwordImport),
          username: username,
          password: password.isEmpty ? null : password,
          url: url.isEmpty ? null : url,
          note: notes.isEmpty ? null : notes,
          category: category.isNotEmpty ? category : tr.passwordImport,
        ),
      );
    }

    return items;
  }

  static List<VaultItem> parseChromeCsv(String content) {
    final rows = _parseCsvRows(content);
    if (rows.isEmpty) return [];

    const uuid = Uuid();
    final items = <VaultItem>[];

    for (final row in rows) {
      final name = _valueFor(row, ['name', 'title']);
      final url = _valueFor(row, ['url', 'origin']);
      final username = _valueFor(row, ['username', 'user']);
      final password = _valueFor(row, ['password']);
      final note = _valueFor(row, ['note', 'notes']);

      if (_isBlank(name) &&
          _isBlank(username) &&
          _isBlank(password) &&
          _isBlank(url)) {
        continue;
      }

      items.add(
        VaultItem(
          id: uuid.v4(),
          type: VaultItemType.password,
          title: name.isNotEmpty
              ? name
              : (url.isNotEmpty ? url : tr.chromeImport),
          username: username,
          password: password.isEmpty ? null : password,
          url: url.isEmpty ? null : url,
          note: note.isEmpty ? null : note,
          category: tr.chromeImport,
        ),
      );
    }

    return items;
  }

  static List<VaultItem> parseSecurePassCsv(String content) {
    final rows = _parseCsvRows(content);
    if (rows.isEmpty) return [];

    const uuid = Uuid();
    final items = <VaultItem>[];

    for (final row in rows) {
      final typeRaw = _valueFor(row, ['type']);
      final type = _parseType(typeRaw);
      final title = _valueFor(row, ['title', 'name']);
      final username = _valueFor(row, ['username', 'user']);
      final password = _valueFor(row, ['password']);
      final secret = _valueFor(row, ['secret']);
      final periodRaw = _valueFor(row, ['period']);
      final url = _valueFor(row, ['url']);
      final note = _valueFor(row, ['note', 'notes']);
      final category = _valueFor(row, ['category']);
      final email = _valueFor(row, ['email']);
      final network = _valueFor(row, ['network']);
      final address = _valueFor(row, ['address']);
      final privateKey = _valueFor(row, ['privatekey', 'private_key']);
      final mnemonic = _valueFor(row, ['mnemonic']);

      if (_isBlank(title) &&
          _isBlank(username) &&
          _isBlank(password) &&
          _isBlank(url)) {
        continue;
      }

      final period = int.tryParse(periodRaw) ?? 30;

      items.add(
        VaultItem(
          id: uuid.v4(),
          type: type,
          title: title.isNotEmpty
              ? title
              : (url.isNotEmpty ? url : tr.passwordvaultImport),
          username: username,
          password: password.isEmpty ? null : password,
          secret: secret.isEmpty ? null : secret,
          period: period,
          url: url.isEmpty ? null : url,
          note: note.isEmpty ? null : note,
          category: category.isEmpty ? null : category,
          email: email.isEmpty ? null : email,
          network: network.isEmpty ? null : network,
          address: address.isEmpty ? null : address,
          privateKey: privateKey.isEmpty ? null : privateKey,
          mnemonic: mnemonic.isEmpty ? null : mnemonic,
        ),
      );
    }

    return items;
  }

  static List<Map<String, String>> _parseCsvRows(String content) {
    // 尝试识别换行符
    String eol = '\n';
    if (content.contains('\r\n')) {
      eol = '\r\n';
    }

    final rows = CsvToListConverter(
      shouldParseNumbers: false,
      eol: eol,
    ).convert(content);

    if (rows.isEmpty) return [];
    final header = rows.first
        .map((e) => e.toString().trim().toLowerCase())
        .toList();
    if (header.where((h) => h.isNotEmpty).isEmpty) return [];

    final List<Map<String, String>> result = [];
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.isEmpty) continue;
      final map = <String, String>{};
      for (var h = 0; h < header.length; h++) {
        final key = header[h];
        if (key.isEmpty) continue;
        map[key] = _safeGet(row, h).trim();
      }
      if (map.isNotEmpty) {
        result.add(map);
      }
    }
    return result;
  }

  static String _valueFor(Map<String, String> row, List<String> keys) {
    for (final key in keys) {
      final value = row[key.toLowerCase()];
      if (value != null && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return '';
  }

  static bool _isBlank(String? value) {
    return value == null || value.trim().isEmpty;
  }

  static VaultItemType _parseType(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'totp') return VaultItemType.totp;
    if (normalized == 'crypto') return VaultItemType.crypto;
    return VaultItemType.password;
  }

  static String _safeGet(List<dynamic> row, int index) {
    if (index >= 0 && index < row.length) {
      return row[index]?.toString() ?? '';
    }
    return '';
  }
}
