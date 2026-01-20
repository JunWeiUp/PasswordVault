import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:path/path.dart' as p;
import 'package:cryptography/cryptography.dart';
import '../../domain/models/webdav_config.dart';
import '../../domain/models/backup_history.dart';
import '../../../vault/presentation/providers/vault_provider.dart';
import '../../../vault/presentation/providers/master_key_provider.dart';
import '../../../vault/domain/models/vault_item.dart';

final webDavConfigProvider = StateNotifierProvider<WebDavConfigNotifier, WebDavConfig>((ref) {
  return WebDavConfigNotifier();
});

class WebDavConfigNotifier extends StateNotifier<WebDavConfig> {
  WebDavConfigNotifier() : super(WebDavConfig(url: '', username: '', password: '')) {
    loadConfig();
  }

  static const _key = 'webdav_config';

  Future<void> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_key);
    if (jsonStr != null) {
      state = WebDavConfig.fromJson(json.decode(jsonStr));
    }
  }

  Future<void> saveConfig(WebDavConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, json.encode(config.toJson()));
    state = config;
  }
}

final backupHistoryProvider = FutureProvider<List<BackupHistory>>((ref) async {
  final config = ref.watch(webDavConfigProvider);
  if (!config.isValid) return [];

  final client = dav.newClient(
    config.url,
    user: config.username,
    password: config.password,
  );

  try {
    // Ensure directory exists
    await client.mkdir(config.backupDirectory);
  } catch (e) {
    // Directory might already exist
  }

  try {
    final files = await client.readDir(config.backupDirectory);
    return files
        .where((f) => f.name != null && f.name!.endsWith('.json'))
        .map((f) => BackupHistory.fromWebDav(
              f.name!,
              f.mTime ?? DateTime.now(),
              f.size ?? 0,
            ))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  } catch (e) {
    return [];
  }
});

final backupServiceProvider = Provider((ref) => BackupService(ref));

class BackupService {
  final Ref _ref;
  BackupService(this._ref);

  Future<bool> testConnection(WebDavConfig config) async {
    final client = dav.newClient(
      config.url,
      user: config.username,
      password: config.password,
    );
    try {
      await client.ping();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> performBackup({bool encrypt = false}) async {
    final config = _ref.read(webDavConfigProvider);
    if (!config.isValid) throw Exception('WebDAV not configured');

    final itemsAsync = _ref.read(vaultItemsProvider);
    final items = itemsAsync.valueOrNull ?? [];
    if (items.isEmpty) throw Exception('No data to backup');

    final client = dav.newClient(
      config.url,
      user: config.username,
      password: config.password,
    );

    try {
      await client.mkdir(config.backupDirectory);
    } catch (e) {}

    final Map<String, dynamic> backupData = {
      'metadata': {
        'version': encrypt ? '1.1.0' : '1.0.0',
        'createdAt': DateTime.now().toIso8601String(),
        'encrypted': encrypt,
      },
    };

    final Map<String, dynamic> itemsData = {
      'items': items.map((e) => e.toJson()).toList(),
    };

    if (encrypt) {
      final masterKey = await _ref.read(masterKeyProvider.future);
      final encryptionService = _ref.read(encryptionServiceProvider);
      if (masterKey == null) throw Exception('主密钥尚未就绪');

      final jsonString = json.encode(itemsData);
      final encryptedBytes = await encryptionService.encrypt(jsonString, masterKey);
      backupData['payload'] = base64.encode(encryptedBytes);
    } else {
      backupData['items'] = itemsData['items'];
    }

    final jsonStr = json.encode(backupData);
    final bytes = utf8.encode(jsonStr);
    final fileName = 'backup_${encrypt ? 'enc_' : ''}${DateTime.now().millisecondsSinceEpoch}.json';
    final remotePath = p.join(config.backupDirectory, fileName);

    await client.write(remotePath, Uint8List.fromList(bytes));
    _ref.invalidate(backupHistoryProvider);
  }

  Future<void> restoreBackup(BackupHistory history) async {
    final config = _ref.read(webDavConfigProvider);
    final client = dav.newClient(
      config.url,
      user: config.username,
      password: config.password,
    );

    final remotePath = p.join(config.backupDirectory, history.fileName);
    final bytes = await client.read(remotePath);
    final jsonStr = utf8.decode(bytes);
    final Map<String, dynamic> data = json.decode(jsonStr);
    
    List<VaultItem> items;
    final metadata = data['metadata'] as Map<String, dynamic>?;
    final bool isEncrypted = metadata?['encrypted'] ?? false;

    if (isEncrypted) {
      final masterKey = await _ref.read(masterKeyProvider.future);
      final encryptionService = _ref.read(encryptionServiceProvider);
      if (masterKey == null) throw Exception('主密钥尚未就绪');

      final String? payloadBase64 = data['payload'] as String?;
      if (payloadBase64 == null) throw Exception('加密备份缺少数据负载');

      final encryptedBytes = base64.decode(payloadBase64);
      final decryptedJson = await encryptionService.decrypt(encryptedBytes, masterKey);
      final Map<String, dynamic> decryptedData = json.decode(decryptedJson);
      final List<dynamic> list = decryptedData['items'];
      items = list.map((e) => VaultItem.fromJson(e)).toList();
    } else {
      final List<dynamic> list = data['items'] ?? data; // 兼容旧格式
      items = list.map((e) => VaultItem.fromJson(e)).toList();
    }
    
    for (final item in items) {
      await _ref.read(vaultItemsProvider.notifier).addItem(item);
    }
  }
}
