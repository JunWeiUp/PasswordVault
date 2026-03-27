import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../vault/domain/models/vault_item.dart';
import '../../domain/totp_engine.dart';
import '../providers/totp_provider.dart';

import '../../../vault/presentation/providers/vault_provider.dart';
import '../../../vault/presentation/widgets/favicon_widget.dart';

class TotpItemCard extends ConsumerWidget {
  final VaultItem item;
  const TotpItemCard({required this.item, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(totpProgressProvider(item.period));
    final code = TotpEngine.generateCode(item.secret ?? '');

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
          final cleanCode = code.replaceAll(' ', '');
          Clipboard.setData(ClipboardData(text: cleanCode));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('验证码已复制到剪贴板'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        onLongPress: () {
          _showActionMenu(context, ref);
        },
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  FaviconWidget(
                    url: item.url,
                    title: item.title,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title, style: Theme.of(context).textTheme.titleMedium),
                        Text(item.username, style: Theme.of(context).textTheme.bodyMedium),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      item.isFavorite ? Icons.star : Icons.star_border,
                      color: item.isFavorite ? Colors.amber : Colors.grey,
                    ),
                    onPressed: () {
                      final updatedItem = item.copyWith(isFavorite: !item.isFavorite);
                      ref.read(vaultItemsProvider.notifier).updateItem(updatedItem);
                    },
                  ),
                ],
              ),
              if (item.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 4,
                    children: item.tags.map((tag) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )).toList(),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(code, style: Theme.of(context).textTheme.displayLarge),
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: progress,
                        strokeWidth: 4,
                        backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                      ),
                      Text(
                        "${(progress * item.period).toInt()}",
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showActionMenu(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑项目'),
              onTap: () {
                Navigator.pop(context);
                context.push('/add-account', extra: item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('导出为 otpauth URI'),
              subtitle: const Text('用于导入到其他 2FA 应用'),
              onTap: () {
                Navigator.pop(context);
                _exportAsUri(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除项目', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteConfirm(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _exportAsUri(BuildContext context) {
    final issuer = Uri.encodeComponent(item.title);
    final account = Uri.encodeComponent(item.username);
    final secret = item.secret ?? '';
    final uri = 'otpauth://totp/$issuer:$account?secret=$secret&issuer=$issuer';

    Clipboard.setData(ClipboardData(text: uri));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('otpauth URI 已复制到剪贴板'),
        duration: Duration(seconds: 3),
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
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('移至回收站'),
          ),
        ],
      ),
    );
  }
}
