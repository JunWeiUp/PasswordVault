import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/security/encryption_service.dart';
import '../../../../core/extension/extension_helper.dart';
import '../../domain/models/vault_item.dart';
import '../../data/repositories/vault_repository.dart';
import 'master_key_provider.dart';
import '../../../../main.dart' show searchQueryProvider;

final databaseProvider = Provider((ref) => AppDatabase());
final encryptionServiceProvider = Provider((ref) => EncryptionService());

final vaultRepositoryProvider = Provider((ref) {
  final db = ref.watch(databaseProvider);
  final encryptionService = ref.watch(encryptionServiceProvider);
  return VaultRepository(db, encryptionService);
});

final sharedVaultsProvider = FutureProvider<List<SharedVault>>((ref) async {
  final repository = ref.watch(vaultRepositoryProvider);
  final userKeyPair = await ref.watch(userKeyPairProvider.future);
  
  if (userKeyPair == null) return [];
  
  return repository.getSharedVaults(userKeyPair);
});

final sharedVaultByIdProvider = FutureProvider.family<SharedVault?, String>((ref, vaultId) async {
  final vaults = await ref.watch(sharedVaultsProvider.future);
  try {
    return vaults.firstWhere((v) => v.id == vaultId);
  } catch (_) {
    return null;
  }
});

final vaultMembersProvider = FutureProvider.family<List<SharedMember>, String>((ref, vaultId) async {
  final repository = ref.watch(vaultRepositoryProvider);
  return repository.getVaultMembers(vaultId);
});

class VaultNotifier extends StateNotifier<AsyncValue<List<VaultItem>>> {
  final VaultRepository _repository;
  final Ref _ref;

  VaultNotifier(this._repository, this._ref) : super(const AsyncValue.loading()) {
    // 监听主密钥状态，当密钥可用或变化时自动刷新
    _ref.listen(masterKeyProvider, (previous, next) {
      if (next is AsyncData && next.value != null) {
        refresh();
      }
    }, fireImmediately: true);
  }

  Future<void> refresh() async {
    // 如果已经在加载，不要重复设置 loading 状态，除非是初始加载
    if (state is! AsyncLoading) {
      // 保持旧数据，显示进度条
      state = AsyncLoading<List<VaultItem>>().copyWithPrevious(state);
    }

    final masterKeyAsync = _ref.read(masterKeyProvider);
    final masterKey = masterKeyAsync.valueOrNull;
    final userKeyPair = await _ref.read(userKeyPairProvider.future);
    
    final fallbacks = _ref.read(fallbackKeysProvider).valueOrNull;
    
    if (masterKey == null) {
      state = const AsyncValue.data([]);
      return;
    }

    try {
      final items = await _repository.getAllItems(masterKey, fallbacks: fallbacks, userKeyPair: userKeyPair);
      state = AsyncValue.data(items);
      
      // 同步域名列表到扩展
      try {
        _syncDomainsToExtension(items);
      } catch (e) {
        debugPrint('Failed to sync domains to extension: $e');
      }
    } catch (e, st) {
      print('Refresh failed: $e');
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> clearAllData() async {
    state = const AsyncValue.loading();
    try {
      await _repository.deleteAllData();
      state = const AsyncValue.data([]);
      
      // 显式使其他相关 provider 失效，强制刷新
      _ref.invalidate(sharedVaultsProvider);
      _ref.invalidate(deletedVaultItemsProvider);
      
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> _syncDomainsToExtension(List<VaultItem> items) async {
    if (!ExtensionHelper.isExtension) return;

    try {
      final domains = <String>{};
      final Map<String, List<Map<String, String>>> accountsMetadata = {};
      final sha256 = Sha256();

      for (final item in items) {
        if (item.type != VaultItemType.password || item.url == null || item.url!.isEmpty) continue;

        // 支持逗号或分号分隔的多个域名/URL
        final rawUrls = item.url!.split(RegExp(r'[,\n;]')).map((u) => u.trim()).where((u) => u.isNotEmpty);

        for (final rawUrl in rawUrls) {
          String domain;
          try {
            final uri = Uri.parse(rawUrl);
            domain = uri.host.toLowerCase();
            if (domain.isEmpty) {
              // 可能是直接输入了域名，如 google.com
              domain = rawUrl.toLowerCase();
            }
          } catch (e) {
            domain = rawUrl.toLowerCase();
          }
          if (domain.isEmpty) continue;

          domains.add(domain);

          final accounts = accountsMetadata.putIfAbsent(domain, () => []);
          
          // 添加主账号 (如果尚未添加)
          if (item.username.isNotEmpty) {
            final pwd = item.password ?? '';
            final hash = await sha256.hash(utf8.encode(pwd));
            final newAccount = {
              'username': item.username,
              'passwordHash': base64Encode(hash.bytes),
            };
            
            // 避免在同一个域名下重复添加相同的用户名
            if (!accounts.any((a) => a['username'] == item.username)) {
              accounts.add(newAccount);
            }
          }
          
          // 添加额外账号
          if (item.accounts != null) {
            for (final acc in item.accounts!) {
              final hash = await sha256.hash(utf8.encode(acc.password));
              final newAccount = {
                'username': acc.username,
                'passwordHash': base64Encode(hash.bytes),
              };
              
              if (!accounts.any((a) => a['username'] == acc.username)) {
                accounts.add(newAccount);
              }
            }
          }
        }
      }

      await ExtensionHelper.syncKnownDomains(domains.toList());
      await ExtensionHelper.syncKnownAccounts(accountsMetadata);
    } catch (e) {
      debugPrint('Error in _syncDomainsToExtension: $e');
    }
  }

  Future<void> addItem(VaultItem item) async {
    try {
      final masterKey = await _ref.read(masterKeyProvider.future);
      if (masterKey == null) throw Exception('主密钥尚未就绪');

      final userKeyPair = await _ref.read(userKeyPairProvider.future);

      await _repository.addItem(item, masterKey, userKeyPair: userKeyPair);
      await refresh();
    } catch (e) {
      print('Add item failed: $e');
      rethrow;
    }
  }

  Future<void> addItems(List<VaultItem> items) async {
    if (items.isEmpty) return;
    try {
      final masterKey = await _ref.read(masterKeyProvider.future);
      if (masterKey == null) throw Exception('主密钥尚未就绪');
      
      final userKeyPair = await _ref.read(userKeyPairProvider.future);

      await _repository.addItems(items, masterKey, userKeyPair: userKeyPair);
      await refresh();
    } catch (e) {
      print('Add items failed: $e');
      rethrow;
    }
  }

  Future<ImportMergeResult> mergeBackupItems(List<VaultItem> backupItems) async {
    if (backupItems.isEmpty) {
      return const ImportMergeResult(added: 0, updated: 0, skipped: 0);
    }

    final masterKey = await _ref.read(masterKeyProvider.future);
    if (masterKey == null) throw Exception('主密钥尚未就绪');

    final fallbacks = await _ref.read(fallbackKeysProvider.future);
    final userKeyPair = await _ref.read(userKeyPairProvider.future);
    final existingItems = await _repository.getAllItems(
      masterKey, includeDeleted: true, fallbacks: fallbacks, userKeyPair: userKeyPair,
    );
    final existingIndex = <String, VaultItem>{};
    for (final item in existingItems) {
      existingIndex[item.id] = item;
    }

    final sortedBackup = List<VaultItem>.from(backupItems);
    sortedBackup.sort((a, b) =>
      (a.updatedAt ?? DateTime(2000)).compareTo(b.updatedAt ?? DateTime(2000)));

    int added = 0, updated = 0, skipped = 0;

    for (final backupItem in sortedBackup) {
      final existing = existingIndex[backupItem.id];
      if (existing == null) {
        await _repository.addItemPreservingTimestamp(
          backupItem, masterKey, userKeyPair: userKeyPair,
        );
        added++;
      } else {
        final backupTime = backupItem.updatedAt ?? DateTime(2000);
        final localTime = existing.updatedAt ?? DateTime(2000);
        if (backupTime.isAfter(localTime)) {
          await _repository.updateItemFromBackup(
            backupItem, masterKey, userKeyPair: userKeyPair,
          );
          updated++;
        } else {
          skipped++;
        }
      }
    }

    await refresh();
    return ImportMergeResult(added: added, updated: updated, skipped: skipped);
  }

  Future<void> updateItem(VaultItem item) async {
    final masterKey = await _ref.read(masterKeyProvider.future);
    if (masterKey == null) return;

    final userKeyPair = await _ref.read(userKeyPairProvider.future);

    await _repository.updateItem(item, masterKey, userKeyPair: userKeyPair);
    await refresh();
  }

  Future<void> softDeleteItem(String id) async {
    await _repository.softDeleteItem(id);
    await refresh();
    _ref.read(deletedVaultItemsProvider.notifier).refresh();
  }

  Future<void> restoreItem(String id) async {
    await _repository.restoreItem(id);
    await refresh();
    _ref.read(deletedVaultItemsProvider.notifier).refresh();
  }

  Future<void> permanentlyDeleteItem(String id) async {
    await _repository.deleteItem(id);
    await refresh();
    _ref.read(deletedVaultItemsProvider.notifier).refresh();
  }

  Future<ImportMergeResult> mergeImportedItems(List<VaultItem> importedItems) async {
    if (importedItems.isEmpty) {
      return const ImportMergeResult(added: 0, updated: 0, skipped: 0);
    }

    final masterKey = await _ref.read(masterKeyProvider.future);
    if (masterKey == null) {
      throw Exception('主密钥尚未就绪');
    }

    final fallbacks = await _ref.read(fallbackKeysProvider.future);
    final userKeyPair = await _ref.read(userKeyPairProvider.future);
    final existingItems = state.valueOrNull ?? await _repository.getAllItems(masterKey, fallbacks: fallbacks, userKeyPair: userKeyPair);
    final existingIndex = <String, VaultItem>{};
    for (final item in existingItems) {
      final key = _buildMergeKey(item);
      if (key.isNotEmpty && !existingIndex.containsKey(key)) {
        existingIndex[key] = item;
      }
    }

    final seenImportKeys = <String>{};
    final itemsToAdd = <VaultItem>[];
    int updated = 0;
    int skipped = 0;

    for (final item in importedItems) {
      final normalizedItem = _normalizeImportedItem(item);
      final key = _buildMergeKey(normalizedItem);
      if (key.isEmpty) {
        itemsToAdd.add(_withNewId(normalizedItem));
        continue;
      }

      if (seenImportKeys.contains(key)) {
        skipped++;
        continue;
      }
      seenImportKeys.add(key);

      final existing = existingIndex[key];
      if (existing == null) {
        itemsToAdd.add(_withNewId(normalizedItem));
        continue;
      }

      final merged = _mergeForImport(existing, normalizedItem);
      if (_isSameItem(existing, merged)) {
        skipped++;
      } else {
        await _repository.updateItem(merged, masterKey, userKeyPair: userKeyPair);
        updated++;
      }
    }

    if (itemsToAdd.isNotEmpty) {
      await _repository.addItems(itemsToAdd, masterKey, userKeyPair: userKeyPair);
    }

    await refresh();
    return ImportMergeResult(added: itemsToAdd.length, updated: updated, skipped: skipped);
  }

  VaultItem _withNewId(VaultItem item) {
    const uuid = Uuid();
    return VaultItem(
      id: uuid.v4(),
      type: item.type,
      title: item.title,
      username: item.username,
      secret: item.secret,
      password: item.password,
      mnemonic: item.mnemonic,
      privateKey: item.privateKey,
      address: item.address,
      network: item.network,
      period: item.period,
      isFavorite: item.isFavorite,
      url: item.url,
      note: item.note,
      category: item.category,
      email: item.email,
      passwordHistory: item.passwordHistory,
      accounts: item.accounts,
      passwordLastChanged: item.passwordLastChanged,
      passwordDuration: item.passwordDuration,
      tags: item.tags,
      sharedVaultId: item.sharedVaultId,
    );
  }

  VaultItem _normalizeImportedItem(VaultItem item) {
    final title = item.title.trim().isNotEmpty ? item.title.trim() : _deriveTitle(item);
    final username = item.username.trim();
    return VaultItem(
      id: item.id,
      type: item.type,
      title: title.isNotEmpty ? title : '未命名导入',
      username: username,
      secret: _cleanValue(item.secret),
      password: _cleanValue(item.password),
      mnemonic: _cleanValue(item.mnemonic),
      privateKey: _cleanValue(item.privateKey),
      address: _cleanValue(item.address),
      network: _cleanValue(item.network),
      period: item.period,
      isFavorite: item.isFavorite,
      url: _cleanValue(item.url),
      note: _cleanValue(item.note),
      category: _cleanValue(item.category),
      email: _cleanValue(item.email),
      passwordHistory: item.passwordHistory,
      accounts: item.accounts,
      passwordLastChanged: item.passwordLastChanged,
      passwordDuration: item.passwordDuration,
      tags: item.tags,
      sharedVaultId: item.sharedVaultId,
    );
  }

  String _deriveTitle(VaultItem item) {
    if (item.url == null || item.url!.trim().isEmpty) return '';
    try {
      final host = Uri.parse(item.url!.trim()).host;
      return host.isNotEmpty ? host : item.url!.trim();
    } catch (_) {
      return item.url!.trim();
    }
  }

  String _buildMergeKey(VaultItem item) {
    final title = item.title.trim().toLowerCase();
    final username = item.username.trim().toLowerCase();
    final host = _extractHost(item.url);
    final type = item.type.name;
    if (title.isEmpty && username.isEmpty && host.isEmpty) return '';
    return '$type|$title|$username|$host';
  }

  String _extractHost(String? url) {
    if (url == null || url.trim().isEmpty) return '';
    
    // 如果包含多个 URL/域名，取第一个作为主域名（用于标题生成或分类）
    final firstUrl = url.split(RegExp(r'[,\n;]')).first.trim();
    if (firstUrl.isEmpty) return '';
    
    try {
      final uri = Uri.parse(firstUrl);
      final host = uri.host.toLowerCase();
      if (host.isNotEmpty) return host;
      return firstUrl.toLowerCase();
    } catch (_) {
      return firstUrl.toLowerCase();
    }
  }

  VaultItem _mergeForImport(VaultItem existing, VaultItem incoming) {
    return VaultItem(
      id: existing.id,
      type: existing.type,
      title: existing.title.trim().isNotEmpty ? existing.title : incoming.title,
      username: existing.username.trim().isNotEmpty ? existing.username : incoming.username,
      secret: _preferExisting(existing.secret, incoming.secret),
      password: _preferIncoming(existing.password, incoming.password),
      mnemonic: _preferExisting(existing.mnemonic, incoming.mnemonic),
      privateKey: _preferExisting(existing.privateKey, incoming.privateKey),
      address: _preferExisting(existing.address, incoming.address),
      network: _preferExisting(existing.network, incoming.network),
      period: existing.period,
      isFavorite: existing.isFavorite || incoming.isFavorite,
      url: _preferExisting(existing.url, incoming.url),
      note: _preferExisting(existing.note, incoming.note),
      category: _preferExisting(existing.category, incoming.category),
      email: _preferExisting(existing.email, incoming.email),
      passwordHistory: existing.passwordHistory,
      accounts: existing.accounts,
      passwordLastChanged: existing.passwordLastChanged,
      passwordDuration: existing.passwordDuration,
      tags: existing.tags.isNotEmpty ? existing.tags : incoming.tags,
      sharedVaultId: existing.sharedVaultId ?? incoming.sharedVaultId,
    );
  }

  bool _isSameItem(VaultItem a, VaultItem b) {
    return a.title == b.title &&
        a.username == b.username &&
        a.secret == b.secret &&
        a.password == b.password &&
        a.mnemonic == b.mnemonic &&
        a.privateKey == b.privateKey &&
        a.address == b.address &&
        a.network == b.network &&
        a.url == b.url &&
        a.note == b.note &&
        a.category == b.category &&
        a.email == b.email &&
        a.isFavorite == b.isFavorite &&
        listEquals(a.tags, b.tags);
  }

  String? _cleanValue(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String? _preferExisting(String? existing, String? incoming) {
    final existingValue = _cleanValue(existing);
    if (existingValue != null) return existingValue;
    return _cleanValue(incoming);
  }

  String? _preferIncoming(String? existing, String? incoming) {
    final incomingValue = _cleanValue(incoming);
    if (incomingValue != null && incomingValue != _cleanValue(existing)) {
      return incomingValue;
    }
    return _cleanValue(existing);
  }
}

class ImportMergeResult {
  final int added;
  final int updated;
  final int skipped;

  const ImportMergeResult({
    required this.added,
    required this.updated,
    required this.skipped,
  });
}

class DeletedVaultNotifier extends StateNotifier<AsyncValue<List<VaultItem>>> {
  final VaultRepository _repository;
  final Ref _ref;

  DeletedVaultNotifier(this._repository, this._ref) : super(const AsyncValue.loading()) {
    _ref.listen(masterKeyProvider, (previous, next) {
      if (next is AsyncData && next.value != null) {
        refresh();
      }
    }, fireImmediately: true);
  }

  Future<void> refresh() async {
    if (state is! AsyncLoading) {
      state = AsyncLoading<List<VaultItem>>().copyWithPrevious(state);
    }

    final masterKey = _ref.read(masterKeyProvider).valueOrNull;
    final fallbacks = _ref.read(fallbackKeysProvider).valueOrNull;
    if (masterKey == null) {
      state = const AsyncValue.data([]);
      return;
    }

    try {
      final userKeyPair = await _ref.read(userKeyPairProvider.future);
      final items = await _repository.getAllItems(masterKey, includeDeleted: true, fallbacks: fallbacks, userKeyPair: userKeyPair);
      state = AsyncValue.data(items.where((item) => item.isDeleted).toList());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

final vaultItemsProvider = StateNotifierProvider<VaultNotifier, AsyncValue<List<VaultItem>>>((ref) {
  final repository = ref.watch(vaultRepositoryProvider);
  return VaultNotifier(repository, ref);
});

final deletedVaultItemsProvider = StateNotifierProvider<DeletedVaultNotifier, AsyncValue<List<VaultItem>>>((ref) {
  final repository = ref.watch(vaultRepositoryProvider);
  return DeletedVaultNotifier(repository, ref);
});

// --- Category & Network Providers ---

final networksProvider = StateProvider<List<String>>((ref) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  return vaultAsync.maybeWhen(
    data: (items) {
      final networks = items
          .where((item) => item.type == VaultItemType.crypto && item.network != null)
          .map((item) => item.network!)
          .toSet()
          .toList();
      
      // 默认网络
      const defaultNetworks = ['ETH', 'BTC', 'BSC', 'Polygon', 'Solana', 'TRON', 'AVAX', 'Arbitrum', 'Optimism'];
      for (var net in defaultNetworks) {
        if (!networks.contains(net)) {
          networks.add(net);
        }
      }
      return networks;
    },
    orElse: () => ['ETH', 'BTC', 'BSC', 'Polygon', 'Solana', 'TRON', 'AVAX', 'Arbitrum', 'Optimism'],
  );
});

// --- Password Health Check ---

enum PasswordHealthIssue { weak, reused, expired }

class PasswordHealthReport {
  final Map<String, List<PasswordHealthIssue>> itemIssues;
  final int weakCount;
  final int reusedCount;
  final int expiredCount;

  PasswordHealthReport({
    required this.itemIssues,
    required this.weakCount,
    required this.reusedCount,
    required this.expiredCount,
  });

  bool hasIssues(String id) => itemIssues.containsKey(id) && itemIssues[id]!.isNotEmpty;
  List<PasswordHealthIssue> getIssues(String id) => itemIssues[id] ?? [];
}

final passwordHealthProvider = Provider<PasswordHealthReport>((ref) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  
  return vaultAsync.maybeWhen(
    data: (items) {
      final itemIssues = <String, List<PasswordHealthIssue>>{};
      final passwordCounts = <String, int>{};
      int weakCount = 0;
      int reusedCount = 0;
      int expiredCount = 0;

      // 1. 统计密码使用频率并检查弱密码和过期
      for (final item in items) {
        if (item.type != VaultItemType.password || item.password == null || item.password!.isEmpty) continue;
        
        final issues = <PasswordHealthIssue>[];
        final password = item.password!;
        
        // 检查频率
        passwordCounts[password] = (passwordCounts[password] ?? 0) + 1;

        // 检查弱密码 (长度 < 8 或 只有一种字符)
        bool isWeak = password.length < 8;
        if (!isWeak) {
          int charTypes = 0;
          if (password.contains(RegExp(r'[a-z]'))) charTypes++;
          if (password.contains(RegExp(r'[A-Z]'))) charTypes++;
          if (password.contains(RegExp(r'[0-9]'))) charTypes++;
          if (password.contains(RegExp(r'[^a-zA-Z0-9]'))) charTypes++;
          if (charTypes <= 1) isWeak = true;
        }

        if (isWeak) {
          issues.add(PasswordHealthIssue.weak);
          weakCount++;
        }

        // 检查过期
        if (item.passwordDuration != null && item.passwordLastChanged != null) {
          final expiryDate = item.passwordLastChanged!.add(Duration(days: item.passwordDuration!));
          if (DateTime.now().isAfter(expiryDate)) {
            issues.add(PasswordHealthIssue.expired);
            expiredCount++;
          }
        }

        if (issues.isNotEmpty) {
          itemIssues[item.id] = issues;
        }
      }

      // 2. 检查重复密码
      for (final item in items) {
        if (item.type != VaultItemType.password || item.password == null) continue;
        
        if ((passwordCounts[item.password!] ?? 0) > 1) {
          final issues = itemIssues[item.id] ?? [];
          if (!issues.contains(PasswordHealthIssue.reused)) {
            issues.add(PasswordHealthIssue.reused);
            itemIssues[item.id] = issues;
            reusedCount++;
          }
        }
      }

      return PasswordHealthReport(
        itemIssues: itemIssues,
        weakCount: weakCount,
        reusedCount: reusedCount,
        expiredCount: expiredCount,
      );
    },
    orElse: () => PasswordHealthReport(
      itemIssues: {},
      weakCount: 0,
      reusedCount: 0,
      expiredCount: 0,
    ),
  );
});

final categoriesProvider = StateProvider<List<String>>((ref) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  return vaultAsync.maybeWhen(
    data: (items) {
      final categories = items
          .map((item) => item.category ?? '未分类')
          .toSet()
          .toList();
      
      // 默认分类
      const defaultCategories = ['社交媒体', '财务', '工作', '购物', '娱乐', '加密资产', '笔记'];
      for (var cat in defaultCategories) {
        if (!categories.contains(cat)) {
          categories.add(cat);
        }
      }
      return categories..sort();
    },
    orElse: () => ['社交媒体', '财务', '工作', '购物', '娱乐', '加密资产', '笔记'],
  );
});

final selectedCategoryProvider = StateProvider<String?>((ref) => null);
final selectedTagProvider = StateProvider<String?>((ref) => null);
final selectedSharedVaultIdProvider = StateProvider<String?>((ref) => null);
final showFavoritesOnlyProvider = StateProvider<bool>((ref) => false);

final allTagsProvider = Provider<List<String>>((ref) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  return vaultAsync.maybeWhen(
    data: (items) {
      final tags = <String>{};
      for (final item in items) {
        tags.addAll(item.tags);
      }
      return tags.toList()..sort();
    },
    orElse: () => [],
  );
});

final vaultItemsBySharedVaultProvider = Provider.family<List<VaultItem>, String>((ref, vaultId) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  return vaultAsync.maybeWhen(
    data: (items) => items.where((item) => item.sharedVaultId == vaultId).toList(),
    orElse: () => [],
  );
});

final filteredVaultItemsProvider = Provider.family<List<VaultItem>, VaultItemType>((ref, type) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  final selectedCategory = ref.watch(selectedCategoryProvider);
  final selectedTag = ref.watch(selectedTagProvider);
  final selectedSharedVaultId = ref.watch(selectedSharedVaultIdProvider);
  final showFavoritesOnly = ref.watch(showFavoritesOnlyProvider);
  final searchQuery = ref.watch(searchQueryProvider).toLowerCase();
  
  return vaultAsync.maybeWhen(
    data: (items) {
      return items.where((item) {
        final matchesType = item.type == type;
        final matchesCategory = selectedCategory == null || item.category == selectedCategory;
        final matchesTag = selectedTag == null || item.tags.contains(selectedTag);
        final matchesSharedVault = selectedSharedVaultId == null || item.sharedVaultId == selectedSharedVaultId;
        final matchesFavorite = !showFavoritesOnly || item.isFavorite;
        
        final matchesSearch = searchQuery.isEmpty || 
            (item.title.toLowerCase().contains(searchQuery)) ||
            (item.username.toLowerCase().contains(searchQuery)) ||
            (item.url?.toLowerCase().contains(searchQuery) ?? false) ||
            (item.note?.toLowerCase().contains(searchQuery) ?? false) ||
            (item.tags.any((tag) => tag.toLowerCase().contains(searchQuery)));

        return matchesType && matchesCategory && matchesTag && matchesSharedVault && matchesFavorite && matchesSearch;
      }).toList();
    },
    orElse: () => [],
  );
});
