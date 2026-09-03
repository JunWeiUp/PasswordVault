import 'package:password/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vault_provider.dart';
import '../../domain/models/vault_item.dart';

class RecycleBinPage extends ConsumerWidget {
  const RecycleBinPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final deletedItemsAsync = ref.watch(deletedVaultItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr.trash),
        actions: [
          deletedItemsAsync.when(
            data: (items) => items.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.delete_forever),
                    onPressed: () => _showEmptyBinDialog(context, ref, items),
                    tooltip: tr.emptyTrash,
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
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.delete_outline,
                    size: 64,
                    color: Colors.grey,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr.trashIsEmpty,
                    style: const TextStyle(color: Colors.grey),
                  ),
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
        error: (error, _) => Center(child: Text(tr.couldNotLoad(error))),
      ),
    );
  }

  Widget _buildDeletedItemCard(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
        leading: _getIconForType(item.type),
        title: Text(item.title),
        subtitle: Text(
          item.username.isNotEmpty ? item.username : (item.url ?? tr.noDetails),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.restore, color: Colors.green),
              onPressed: () => _restoreItem(context, ref, item),
              tooltip: tr.restore,
            ),
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              onPressed: () => _permanentlyDeleteItem(context, ref, item),
              tooltip: tr.deletePermanently,
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr.restored(item.title))));
  }

  void _permanentlyDeleteItem(
    BuildContext context,
    WidgetRef ref,
    VaultItem item,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.deletePermanently),
        content: Text(tr.permanentlyDeleteThisCannotBeUndone(item.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(vaultItemsProvider.notifier)
                  .permanentlyDeleteItem(item.id);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(tr.permanentlyDeleted(item.title))),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(tr.deletePermanently),
          ),
        ],
      ),
    );
  }

  void _showEmptyBinDialog(
    BuildContext context,
    WidgetRef ref,
    List<VaultItem> items,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.emptyTrash),
        content: Text(tr.permanentlyDeleteAllItemsInTheTrash(items.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () {
              for (final item in items) {
                ref
                    .read(vaultItemsProvider.notifier)
                    .permanentlyDeleteItem(item.id);
              }
              Navigator.pop(context);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(tr.trashEmptied)));
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(tr.empty),
          ),
        ],
      ),
    );
  }
}
