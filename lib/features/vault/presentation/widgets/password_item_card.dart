import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../domain/models/vault_item.dart';
import '../../../totp/domain/totp_engine.dart';
import '../../../totp/presentation/providers/totp_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vault_provider.dart';
import '../../../../core/extension/extension_helper.dart';

class PasswordItemCard extends ConsumerWidget {
  final VaultItem item;
  const PasswordItemCard({required this.item, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool isExpired = _checkIsExpired();
    final int? remainingDays = _getRemainingDays();
    final bool hasTotp = item.secret != null && item.secret!.isNotEmpty;
    final bool hasMultipleAccounts = item.accounts != null && item.accounts!.isNotEmpty;
    
    String? totpCode;
    double? totpProgress;
    
    if (hasTotp) {
      totpProgress = ref.watch(totpProgressProvider(item.period));
      totpCode = TotpEngine.generateCode(item.secret!);
    }

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: isExpired 
            ? Colors.red.withOpacity(0.5) 
            : Theme.of(context).dividerColor.withOpacity(0.1)
        ),
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
              // 网站图标占位
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isExpired 
                    ? Colors.red.withOpacity(0.1)
                    : Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  isExpired ? Icons.warning_amber_rounded : Icons.vpn_key_outlined,
                  color: isExpired 
                    ? Colors.red 
                    : Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (hasMultipleAccounts)
                          Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.secondary.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Theme.of(context).colorScheme.secondary.withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.people_outline, size: 10, color: Theme.of(context).colorScheme.secondary),
                                const SizedBox(width: 2),
                                Text(
                                  '${item.accounts!.length + 1}',
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.secondary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (isExpired)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '已过期',
                              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          )
                        else if (remainingDays != null && remainingDays <= 7)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '$remainingDays天后过期',
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                      ],
                    ),
                    Text(
                      item.username,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (item.url != null && item.url!.isNotEmpty)
                      Text(
                        item.url!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (hasTotp) ...[
                      const SizedBox(height: 8),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: totpCode!.replaceAll(' ', '')));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('验证码已复制到剪贴板'), duration: Duration(seconds: 2)),
                          );
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.timer_outlined, size: 14, color: Colors.grey),
                              const SizedBox(width: 6),
                              Text(
                                totpCode!,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(width: 10),
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  value: totpProgress,
                                  strokeWidth: 2,
                                  backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (ExtensionHelper.isExtension)
                IconButton(
                  icon: const Icon(Icons.auto_fix_high),
                  onPressed: () {
                    ExtensionHelper.fillCredentials(item.username, item.password ?? '');
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('正在自动填充...'), duration: Duration(seconds: 1)),
                    );
                  },
                  tooltip: '自动填充',
                color: Theme.of(context).colorScheme.primary,
              ),
            if (hasMultipleAccounts)
              PopupMenuButton<AccountEntry?>(
                icon: const Icon(Icons.copy),
                tooltip: '复制密码',
                onSelected: (account) {
                  final password = account?.password ?? item.password ?? '';
                  Clipboard.setData(ClipboardData(text: password));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('${account?.label ?? account?.username ?? '默认账号'} 密码已复制'), duration: const Duration(seconds: 2)),
                  );
                },
                itemBuilder: (context) => [
                  PopupMenuItem<AccountEntry?>(
                    value: null,
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text('默认: ${item.username}')),
                      ],
                    ),
                  ),
                  ...item.accounts!.map((acc) => PopupMenuItem<AccountEntry?>(
                    value: acc,
                    child: Row(
                      children: [
                        const Icon(Icons.person_outline, size: 20),
                        const SizedBox(width: 8),
                        Expanded(child: Text('${acc.label ?? '账号'}: ${acc.username}')),
                      ],
                    ),
                  )),
                ],
              )
            else
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: item.password ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('密码已复制'), duration: Duration(seconds: 2)),
                  );
                },
                tooltip: '复制密码',
              ),
          ],
        ),
        ),
      ),
    );
  }

  bool _checkIsExpired() {
    if (item.passwordDuration == null || item.passwordLastChanged == null) return false;
    final expiryDate = item.passwordLastChanged!.add(Duration(days: item.passwordDuration!));
    return DateTime.now().isAfter(expiryDate);
  }

  int? _getRemainingDays() {
    if (item.passwordDuration == null || item.passwordLastChanged == null) return null;
    final expiryDate = item.passwordLastChanged!.add(Duration(days: item.passwordDuration!));
    final difference = expiryDate.difference(DateTime.now()).inDays;
    return difference;
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
