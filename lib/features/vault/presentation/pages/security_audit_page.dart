import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vault_provider.dart';
import '../widgets/password_item_card.dart';

class SecurityAuditPage extends ConsumerWidget {
  const SecurityAuditPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final healthReport = ref.watch(passwordHealthProvider);
    final vaultItemsAsync = ref.watch(vaultItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('安全审计'),
      ),
      body: vaultItemsAsync.when(
        data: (items) {
          final itemsWithIssues = items.where((item) => healthReport.hasIssues(item.id)).toList();

          if (itemsWithIssues.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline, color: Colors.green, size: 80),
                  SizedBox(height: 16),
                  Text('您的密码库非常安全！', style: TextStyle(fontSize: 18)),
                ],
              ),
            );
          }

          return Column(
            children: [
              _buildSummaryHeader(context, healthReport),
              Expanded(
                child: ListView.builder(
                  itemCount: itemsWithIssues.length,
                  itemBuilder: (context, index) {
                    return PasswordItemCard(item: itemsWithIssues[index]);
                  },
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('加载失败: $e')),
      ),
    );
  }

  Widget _buildSummaryHeader(BuildContext context, PasswordHealthReport report) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStat(context, '弱密码', report.weakCount, Colors.red),
          _buildStat(context, '重复使用', report.reusedCount, Colors.orange),
          _buildStat(context, '已过期', report.expiredCount, Colors.blue),
        ],
      ),
    );
  }

  Widget _buildStat(BuildContext context, String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
