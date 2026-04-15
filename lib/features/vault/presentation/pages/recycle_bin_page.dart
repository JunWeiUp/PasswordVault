import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vault_provider.dart';
import '../../domain/models/vault_item.dart';

class RecycleBinPage extends ConsumerWidget {
  const RecycleBinPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deletedItemsAsync = ref.watch(deletedVaultItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          deletedItemsAsync.when(
            data: (items) => items.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.delete_forever),
                    onPressed: () => _showEmptyBinDialog(context, ref, items),
                    tooltip: '清空回收站',
                  )
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: deletedItemsAsync.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.delete_outline, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('回收站是空的', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: items.length,
            padding: const EdgeInsets.all(8),
            itemBuilder: (context, index) {
              final item = items[index];
              return _buildDeletedItemCard(context, ref, item);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败: $error')),
      ),
    );
  }

  Widget _buildDeletedItemCard(BuildContext context, WidgetRef ref, VaultItem item) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
        leading: _getIconForType(item.type),
        title: Text(item.title),
        subtitle: Text(
          item.username.isNotEmpty ? item.username : (item.url ?? '无详情'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.restore, color: Colors.green),
              onPressed: () => _restoreItem(context, ref, item),
              tooltip: '恢复',
            ),
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              onPressed: () => _permanentlyDeleteItem(context, ref, item),
              tooltip: '永久删除',
            ),
          ],
        ),
      ),
    );
  }

  Icon _getIconForType(VaultItemType type) {
    switch (type) {
      case VaultItemType.password:
        return const Icon(Icons.password);
      case VaultItemType.totp:
        return const Icon(Icons.timer);
      case VaultItemType.secureNote:
        return const Icon(Icons.note);
      case VaultItemType.crypto:
        return const Icon(Icons.currency_bitcoin);
    }
  }

  void _restoreItem(BuildContext context, WidgetRef ref, VaultItem item) {
    ref.read(vaultItemsProvider.notifier).restoreItem(item.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已恢复: ${item.title}')),
    );
  }

  void _permanentlyDeleteItem(BuildContext context, WidgetRef ref, VaultItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除'),
        content: Text('确定要永久删除 "${item.title}" 吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.read(vaultItemsProvider.notifier).permanentlyDeleteItem(item.id);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已永久删除: ${item.title}')),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
  }

  void _showEmptyBinDialog(BuildContext context, WidgetRef ref, List<VaultItem> items) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空回收站'),
        content: Text('确定要清空回收站中的 ${items.length} 个项目吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              for (final item in items) {
                ref.read(vaultItemsProvider.notifier).permanentlyDeleteItem(item.id);
              }
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('回收站已清空')),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
  }
}
