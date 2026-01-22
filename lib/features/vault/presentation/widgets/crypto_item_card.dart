import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../domain/models/vault_item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vault_provider.dart';

class CryptoItemCard extends ConsumerWidget {
  final VaultItem item;
  const CryptoItemCard({required this.item, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).dividerColor.withOpacity(0.1)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          context.push('/add-account', extra: item);
        },
        onLongPress: () {
          _showDeleteConfirm(context, ref);
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.currency_bitcoin,
                  color: Colors.orange,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (item.network != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            item.network!,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.blue[700],
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    if (item.address != null && item.address!.isNotEmpty)
                      Text(
                        item.address!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (item.note != null && item.note!.isNotEmpty)
                      Text(
                        item.note!,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                if (item.address != null) {
                  Clipboard.setData(ClipboardData(text: item.address!));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('地址已复制'), duration: Duration(seconds: 2)),
                  );
                }
              },
              tooltip: '复制地址',
            ),
            IconButton(
              icon: Icon(
                item.isFavorite ? Icons.star : Icons.star_border,
                color: item.isFavorite ? Colors.amber : Colors.grey,
              ),
              onPressed: () {
                final updatedItem = VaultItem(
                  id: item.id,
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
                  isFavorite: !item.isFavorite,
                  url: item.url,
                  note: item.note,
                  category: item.category,
                  email: item.email,
                  passwordHistory: item.passwordHistory,
                  accounts: item.accounts,
                  passwordLastChanged: item.passwordLastChanged,
                  passwordDuration: item.passwordDuration,
                );
                ref.read(vaultItemsProvider.notifier).updateItem(updatedItem);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

  void _showDeleteConfirm(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除确认'),
        content: Text('确定要删除 ${item.title} 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              ref.read(vaultItemsProvider.notifier).softDeleteItem(item.id);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已移至回收站')),
              );
            },
            child: const Text('移至回收站', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
