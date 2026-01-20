import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webdav_client/webdav_client.dart' as dav;
import 'package:path/path.dart' as p;
import '../../domain/models/webdav_config.dart';
import '../../domain/models/backup_history.dart';
import '../../../vault/presentation/providers/vault_provider.dart';
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

  Future<void> performBackup() async {
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

    final jsonStr = json.encode(items.map((e) => e.toJson()).toList());
    final bytes = utf8.encode(jsonStr);
    final fileName = 'backup_${DateTime.now().millisecondsSinceEpoch}.json';
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
    final List<dynamic> list = json.decode(jsonStr);
    
    final items = list.map((e) => VaultItem.fromJson(e)).toList();
    
    for (final item in items) {
      await _ref.read(vaultItemsProvider.notifier).addItem(item);
    }
  }
}
