import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:path/path.dart' as p;
import 'package:cryptography/cryptography.dart';
import '../../../../core/security/secure_storage_service.dart';
import '../../domain/models/webdav_config.dart';
import '../../domain/models/backup_history.dart';
import '../../../vault/presentation/providers/vault_provider.dart';
import '../../../vault/presentation/providers/master_key_provider.dart';
import '../../../vault/domain/models/vault_item.dart';

/// Web 端（含浏览器扩展）若首次请求不带 Authorization，服务器返回 401 时 Chrome 会弹出系统级 HTTP Basic 登录框，
/// 早于 webdav_client 内部的二次协商。因此在 [kIsWeb] 且已填写账号密码时，从首包即发送 Basic 认证。
dav.Client _webDavClient(WebDavConfig config) {
  final url = config.url.trim();
  final user = config.username;
  final password = config.password;

  if (kIsWeb && user.isNotEmpty && password.isNotEmpty) {
    final uri = url.endsWith('/') ? url : '$url/';
    return dav.Client(
      uri: uri,
      c: dav.WdDio(),
      auth: dav.BasicAuth(user: user, pwd: password),
      debug: false,
    );
  }

  return dav.newClient(url, user: user, password: password);
}

final webDavConfigProvider = StateNotifierProvider<WebDavConfigNotifier, WebDavConfig>((ref) {
  return WebDavConfigNotifier();
});

class WebDavConfigNotifier extends StateNotifier<WebDavConfig> {
  WebDavConfigNotifier() : super(WebDavConfig(url: '', username: '', password: '')) {
    loadConfig();
  }

  static const _key = 'webdav_config';
  final _secureStorage = SecureStorageService();

  Future<void> loadConfig() async {
    String? jsonStr = await _secureStorage.read(_key);
    if (jsonStr == null && !kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      jsonStr = prefs.getString(_key);
      if (jsonStr != null) {
        await _secureStorage.write(_key, jsonStr);
        final verify = await _secureStorage.read(_key);
        if (verify == jsonStr) {
          await prefs.remove(_key);
        }
      }
    }
    if (jsonStr != null) {
      state = WebDavConfig.fromJson(json.decode(jsonStr));
    }
  }

  Future<void> saveConfig(WebDavConfig config) async {
    await _secureStorage.write(_key, json.encode(config.toJson()));
    state = config;
  }

  Future<void> clearConfig() async {
    await _secureStorage.delete(_key);
    state = WebDavConfig(url: '', username: '', password: '');
  }
}

final backupHistoryProvider = FutureProvider<List<BackupHistory>>((ref) async {
  final config = ref.watch(webDavConfigProvider);
  if (!config.isValid) return [];

  final client = _webDavClient(config);

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
    final client = _webDavClient(config);
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

    final repository = _ref.read(vaultRepositoryProvider);
    final masterKey = await _ref.read(masterKeyProvider.future);
    if (masterKey == null) throw Exception('主密钥尚未就绪');

    final fallbacks = await _ref.read(fallbackKeysProvider.future);
    final userKeyPair = await _ref.read(userKeyPairProvider.future);
    final items = await repository.getAllItems(
      masterKey,
      includeDeleted: true,
      fallbacks: fallbacks,
      userKeyPair: userKeyPair,
    );

    final sharedVaults = userKeyPair != null ? await repository.getSharedVaults(userKeyPair) : <SharedVault>[];
    final sharedMembers = await repository.getAllSharedMembers();

    if (items.isEmpty && sharedVaults.isEmpty) throw Exception('No data to backup');

    final client = _webDavClient(config);

    try {
      await client.mkdir(config.backupDirectory);
    } catch (e) {}

    final Map<String, dynamic> backupData = {
      'metadata': {
        // 1.3.0 / 1.2.0：items 含回收站条目（isDeleted/deletedAt）
        'version': encrypt ? '1.3.0' : '1.2.0',
        'createdAt': DateTime.now().toIso8601String(),
        'encrypted': encrypt,
      },
    };

    final Map<String, dynamic> itemsData = {
      'items': items.map((e) => e.toJson()).toList(),
      'sharedVaults': sharedVaults.map((e) => e.toJson()).toList(),
      'sharedMembers': sharedMembers.map((e) => e.toJson()).toList(),
    };

    if (encrypt) {
      final salt = await _ref.read(masterKeySaltProvider.future);
      final encryptionService = _ref.read(encryptionServiceProvider);
      
      if (salt == null) throw Exception('主密钥尚未就绪');

      final jsonString = json.encode(itemsData);
      final encryptedBytes = await encryptionService.encrypt(jsonString, masterKey);
      
      backupData['payload'] = base64.encode(encryptedBytes);
      final metadata = backupData['metadata'] as Map<String, dynamic>;
      metadata['salt'] = base64.encode(salt);
      metadata['iterations'] = 2;
      metadata['memory'] = 32 * 1024;
      metadata['parallelism'] = 1;
    } else {
      backupData.addAll(itemsData);
    }

    final jsonStr = json.encode(backupData);
    final bytes = utf8.encode(jsonStr);
    final fileName = 'backup_${encrypt ? 'enc_' : ''}${DateTime.now().millisecondsSinceEpoch}.json';
    final remotePath = p.join(config.backupDirectory, fileName);

    await client.write(remotePath, Uint8List.fromList(bytes));
    _ref.invalidate(backupHistoryProvider);
  }

  Future<ImportMergeResult> restoreBackup(BackupHistory history) async {
    final config = _ref.read(webDavConfigProvider);
    final client = _webDavClient(config);

    final remotePath = p.join(config.backupDirectory, history.fileName);
    final bytes = await client.read(remotePath);
    final jsonStr = utf8.decode(bytes);
    final Map<String, dynamic> data = json.decode(jsonStr);
    
    List<VaultItem> items = [];
    List<SharedVault> sharedVaults = [];
    List<SharedMember> sharedMembers = [];
    
    final metadata = data['metadata'] as Map<String, dynamic>?;
    final bool isEncrypted = metadata?['encrypted'] ?? false;

    if (isEncrypted) {
      final masterState = _ref.read(masterPasswordProvider);
      final password = masterState.password;
      if (password == null) throw Exception('主密码未设置，无法解密');

      final encryptionService = _ref.read(encryptionServiceProvider);
      final String? payloadBase64 = data['payload'] as String?;
      if (payloadBase64 == null) throw Exception('加密备份缺少数据负载');

      final encryptedBytes = base64.decode(payloadBase64);
      
      SecretKey decryptionKey;
      final String? saltBase64 = metadata?['salt'] as String?;
      
      if (saltBase64 != null) {
        final salt = base64.decode(saltBase64);
        final iterations = metadata?['iterations'] as int? ?? 2;
        final memory = metadata?['memory'] as int? ?? 32 * 1024;
        final parallelism = metadata?['parallelism'] as int? ?? 1;
        
        decryptionKey = await encryptionService.deriveKey(
          password, 
          salt,
          iterations: iterations,
          memory: memory,
          parallelism: parallelism,
        );
      } else {
        final masterKey = await _ref.read(masterKeyProvider.future);
        if (masterKey == null) throw Exception('主密钥尚未就绪');
        decryptionKey = masterKey;
      }

      try {
        final decryptedJson = await encryptionService.decrypt(encryptedBytes, decryptionKey);
        final Map<String, dynamic> decryptedData = json.decode(decryptedJson);
        
        final List<dynamic> list = decryptedData['items'];
        items = list.map((e) => VaultItem.fromJson(e)).toList();
        
        if (decryptedData.containsKey('sharedVaults')) {
          final List<dynamic> svList = decryptedData['sharedVaults'];
          sharedVaults = svList.map((e) => SharedVault.fromJson(e)).toList();
        }
        
        if (decryptedData.containsKey('sharedMembers')) {
          final List<dynamic> smList = decryptedData['sharedMembers'];
          sharedMembers = smList.map((e) => SharedMember.fromJson(e)).toList();
        }
      } catch (e) {
        if (e.toString().contains('MAC') || e.toString().contains('authentication code')) {
          throw Exception('解密失败：主密码错误或备份数据损坏');
        }
        rethrow;
      }
    } else {
      if (data.containsKey('items')) {
        final List<dynamic> list = data['items'];
        items = list.map((e) => VaultItem.fromJson(e)).toList();
        
        if (data.containsKey('sharedVaults')) {
          final List<dynamic> svList = data['sharedVaults'];
          sharedVaults = svList.map((e) => SharedVault.fromJson(e)).toList();
        }
        
        if (data.containsKey('sharedMembers')) {
          final List<dynamic> smList = data['sharedMembers'];
          sharedMembers = smList.map((e) => SharedMember.fromJson(e)).toList();
        }
      } else {
        // 兼容极旧格式（直接是一个数组）
        final List<dynamic> list = data as List;
        items = list.map((e) => VaultItem.fromJson(e)).toList();
      }
    }
    
    // 恢复数据：按时间合并，不直接覆盖
    final repository = _ref.read(vaultRepositoryProvider);
    if (sharedVaults.isNotEmpty) {
      await repository.mergeSharedVaults(sharedVaults);
    }
    if (sharedMembers.isNotEmpty) {
      await repository.addSharedMembers(sharedMembers);
    }
    final result = await _ref.read(vaultItemsProvider.notifier).mergeBackupItems(items);
    
    // 刷新共享库列表
    _ref.invalidate(sharedVaultsProvider);
    return result;
  }
}
