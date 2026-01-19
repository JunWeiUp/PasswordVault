import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../vault/domain/models/vault_item.dart';
import '../../domain/totp_engine.dart';

import '../../../vault/presentation/providers/vault_provider.dart';

// 订阅秒针的 Provider
final tickerProvider = StreamProvider<int>((ref) {
  return Stream.periodic(const Duration(seconds: 1), (i) => i);
});

final totpProgressProvider = Provider.family<double, int>((ref, period) {
  ref.watch(tickerProvider);
  return TotpEngine.getProgress(period);
});

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
          context.push('/add-account', extra: item);
        },
        onLongPress: () {
          _showActionMenu(context, ref);
        },
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: Theme.of(context).textTheme.titleMedium),
              Text(item.username, style: Theme.of(context).textTheme.bodyMedium),
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
              ref.read(vaultItemsProvider.notifier).deleteItem(item.id);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
