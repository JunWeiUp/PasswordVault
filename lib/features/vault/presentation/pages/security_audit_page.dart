import 'package:password/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/vault_provider.dart';
import '../widgets/password_item_card.dart';

class SecurityAuditPage extends ConsumerWidget {
  const SecurityAuditPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final healthReport = ref.watch(passwordHealthProvider);
    final vaultItemsAsync = ref.watch(vaultItemsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(tr.passwordHealth)),
      body: vaultItemsAsync.when(
        data: (items) {
          final itemsWithIssues = items
              .where((item) => healthReport.hasIssues(item.id))
              .toList();

          if (itemsWithIssues.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    color: Colors.green,
                    size: 80,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr.noWeakReusedOrExpiredPasswordsDetected,
                    style: const TextStyle(fontSize: 18),
                  ),
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
        error: (e, st) => Center(child: Text(tr.couldNotLoad(e))),
      ),
    );
  }

  Widget _buildSummaryHeader(
    BuildContext context,
    PasswordHealthReport report,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStat(context, tr.weakPasswords, report.weakCount, Colors.red),
          _buildStat(context, tr.reused, report.reusedCount, Colors.orange),
          _buildStat(context, tr.expired, report.expiredCount, Colors.blue),
        ],
      ),
    );
  }

  Widget _buildStat(
    BuildContext context,
    String label,
    int count,
    Color color,
  ) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
