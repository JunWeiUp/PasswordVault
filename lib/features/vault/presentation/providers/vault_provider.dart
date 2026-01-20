import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart' hide VaultItem;
import '../../../../core/security/encryption_service.dart';
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
    
    if (masterKey == null) {
      state = const AsyncValue.data([]);
      return;
    }

    try {
      final items = await _repository.getAllItems(masterKey);
      state = AsyncValue.data(items);
    } catch (e, st) {
      print('Refresh failed: $e');
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> addItem(VaultItem item) async {
    try {
      final masterKey = await _ref.read(masterKeyProvider.future);
      if (masterKey == null) throw Exception('主密钥尚未就绪');

      await _repository.addItem(item, masterKey);
      await refresh();
    } catch (e) {
      print('Add item failed: $e');
      rethrow;
    }
  }

  Future<void> updateItem(VaultItem item) async {
    final masterKey = await _ref.read(masterKeyProvider.future);
    if (masterKey == null) return;

    await _repository.updateItem(item, masterKey);
    await refresh();
  }

  Future<void> deleteItem(String id) async {
    await _repository.deleteItem(id);
    await refresh();
  }
}

final vaultItemsProvider = StateNotifierProvider<VaultNotifier, AsyncValue<List<VaultItem>>>((ref) {
  final repository = ref.watch(vaultRepositoryProvider);
  return VaultNotifier(repository, ref);
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

final categoriesProvider = StateProvider<List<String>>((ref) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  return vaultAsync.maybeWhen(
    data: (items) {
      final categories = items
          .map((item) => item.category ?? '未分类')
          .toSet()
          .toList();
      
      // 默认分类
      const defaultCategories = ['社交媒体', '财务', '工作', '购物', '娱乐', '加密资产'];
      for (var cat in defaultCategories) {
        if (!categories.contains(cat)) {
          categories.add(cat);
        }
      }
      return categories..sort();
    },
    orElse: () => ['社交媒体', '财务', '工作', '购物', '娱乐', '加密货币'],
  );
});

final selectedCategoryProvider = StateProvider<String?>((ref) => null);

final filteredVaultItemsProvider = Provider.family<List<VaultItem>, VaultItemType>((ref, type) {
  final vaultAsync = ref.watch(vaultItemsProvider);
  final selectedCategory = ref.watch(selectedCategoryProvider);
  final searchQuery = ref.watch(searchQueryProvider).toLowerCase();
  
  return vaultAsync.maybeWhen(
    data: (items) {
      return items.where((item) {
        final matchesType = item.type == type;
        final matchesCategory = selectedCategory == null || item.category == selectedCategory;
        
        final matchesSearch = searchQuery.isEmpty || 
            (item.title.toLowerCase().contains(searchQuery)) ||
            (item.username?.toLowerCase().contains(searchQuery) ?? false) ||
            (item.url?.toLowerCase().contains(searchQuery) ?? false) ||
            (item.note?.toLowerCase().contains(searchQuery) ?? false);

        return matchesType && matchesCategory && matchesSearch;
      }).toList();
    },
    orElse: () => [],
  );
});
