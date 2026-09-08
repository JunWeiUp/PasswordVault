import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:password/core/l10n/l10n.dart';
import '../../../../core/extension/extension_helper.dart';
import '../../domain/models/vault_item.dart';
import '../../../totp/domain/totp_engine.dart';
import '../../../totp/presentation/providers/totp_provider.dart';
import '../providers/vault_provider.dart';
import 'favicon_widget.dart';

class PasswordItemCard extends ConsumerWidget {
  const PasswordItemCard({required this.item, super.key});

  final VaultItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final isExpired = _checkIsExpired();
    final remainingDays = _getRemainingDays();
    final hasTotp = item.secret != null && item.secret!.isNotEmpty;
    final hasMultipleAccounts = item.accounts?.isNotEmpty ?? false;
    final issues = ref.watch(passwordHealthProvider).getIssues(item.id);
    final badges = <Widget>[
      if (hasMultipleAccounts)
        _StatusPill(label: '${tr.accounts} · ${item.accounts!.length + 1}'),
      if (isExpired)
        _StatusPill(label: tr.expired, isWarning: true)
      else if (remainingDays != null && remainingDays <= 7)
        _StatusPill(label: tr.expiresInDays(remainingDays), isWarning: true),
      if (issues.contains(PasswordHealthIssue.weak))
        _StatusPill(label: tr.weakPasswords, isWarning: true),
      if (issues.contains(PasswordHealthIssue.reused))
        _StatusPill(label: tr.reused, isWarning: true),
      for (final tag in item.tags) _StatusPill(label: tag),
    ];
    final actions = _buildActions(context, ref, hasMultipleAccounts);
    final totp = hasTotp
        ? _buildTotp(
            context,
            TotpEngine.generateCode(item.secret!),
            ref.watch(totpProgressProvider(item.period)),
          )
        : null;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: isExpired ? colors.error : colors.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push('/add-account', extra: item),
        onLongPress: () => _showDeleteConfirm(context, ref),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 620;
            return Padding(
              padding: isWide
                  ? const EdgeInsets.symmetric(horizontal: 16, vertical: 14)
                  : const EdgeInsets.fromLTRB(16, 14, 12, 8),
              child: isWide
                  ? Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildIdentity(context, badges: badges),
                              if (totp != null) ...[
                                const SizedBox(height: 10),
                                totp,
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 16),
                        actions,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildIdentity(context),
                        if (totp != null) ...[const SizedBox(height: 10), totp],
                        const SizedBox(height: 6),
                        // Labels and the action group share a line whenever
                        // they fit, then wrap naturally for larger text.
                        Wrap(
                          alignment: badges.isEmpty
                              ? WrapAlignment.end
                              : WrapAlignment.start,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 4,
                          children: [...badges, actions],
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildIdentity(
    BuildContext context, {
    List<Widget> badges = const [],
  }) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FaviconWidget(url: item.url, title: item.title, size: 44),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.title, style: theme.textTheme.titleMedium),
              if (item.username.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  item.username,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (item.url?.isNotEmpty ?? false) ...[
                const SizedBox(height: 3),
                Text(
                  item.url!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (badges.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 4, children: badges),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTotp(BuildContext context, String code, double progress) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      button: true,
      label: tr.copy,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            _copy(context, code.replaceAll(' ', ''), tr.codeCopiedToClipboard),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(
                Icons.timer_outlined,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
              Text(
                code,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1,
                ),
              ),
              SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 2,
                  backgroundColor: colors.outlineVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    WidgetRef ref,
    bool hasMultipleAccounts,
  ) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 2,
      children: [
        if (ExtensionHelper.isExtension)
          IconButton(
            icon: const Icon(Icons.auto_fix_high_outlined),
            tooltip: tr.autofill,
            color: colors.primary,
            onPressed: () => _fill(context),
          ),
        IconButton(
          icon: Icon(
            item.isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          ),
          color: item.isFavorite ? colors.primary : colors.onSurfaceVariant,
          tooltip: item.isFavorite ? tr.removeFromFavorites : tr.addToFavorites,
          onPressed: () {
            ref
                .read(vaultItemsProvider.notifier)
                .updateItem(item.copyWith(isFavorite: !item.isFavorite));
          },
        ),
        if (hasMultipleAccounts)
          PopupMenuButton<int>(
            icon: const Icon(Icons.copy_outlined),
            tooltip: tr.copyPassword,
            // Zero is the default account. A null menu value is
            // treated by Flutter as cancellation, not selection.
            onSelected: (index) {
              final account = index == 0 ? null : item.accounts![index - 1];
              _copy(
                context,
                account?.password ?? item.password ?? '',
                tr.passwordCopiedFor(
                  account?.label ?? account?.username ?? tr.defaultAccount,
                ),
              );
            },
            itemBuilder: (context) => [
              PopupMenuItem<int>(
                value: 0,
                child: Text(tr.labelDefault385(item.username)),
              ),
              for (var index = 0; index < item.accounts!.length; index++)
                PopupMenuItem<int>(
                  value: index + 1,
                  child: Text(
                    '${item.accounts![index].label ?? tr.account386}: ${item.accounts![index].username}',
                  ),
                ),
            ],
          )
        else
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: tr.copyPassword,
            onPressed: () =>
                _copy(context, item.password ?? '', tr.passwordCopied),
          ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz_rounded),
          tooltip: tr.options,
          onSelected: (action) {
            if (action == 'edit') {
              context.push('/add-account', extra: item);
            } else if (action == 'delete') {
              _showDeleteConfirm(context, ref);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'edit', child: Text(tr.editItem)),
            PopupMenuItem(
              value: 'delete',
              child: Text(
                tr.moveToTrash,
                style: TextStyle(color: colors.error),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _copy(
    BuildContext context,
    String value,
    String successMessage,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (context.mounted) _showMessage(context, successMessage);
    } catch (_) {
      if (context.mounted) _showMessage(context, tr.clipboardWriteFailed);
    }
  }

  Future<void> _fill(BuildContext context) async {
    try {
      await ExtensionHelper.fillCredentials(item.username, item.password ?? '');
      if (context.mounted) _showMessage(context, tr.filledOnTheCurrentPage);
    } catch (_) {
      if (context.mounted) _showMessage(context, tr.fillFailedTryAgain);
    }
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
  }

  bool _checkIsExpired() {
    if (item.passwordDuration == null || item.passwordLastChanged == null) {
      return false;
    }
    final expiryDate = item.passwordLastChanged!.add(
      Duration(days: item.passwordDuration!),
    );
    return DateTime.now().isAfter(expiryDate);
  }

  int? _getRemainingDays() {
    if (item.passwordDuration == null || item.passwordLastChanged == null) {
      return null;
    }
    final expiryDate = item.passwordLastChanged!.add(
      Duration(days: item.passwordDuration!),
    );
    return expiryDate.difference(DateTime.now()).inDays;
  }

  Future<void> _showDeleteConfirm(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr.confirmDeletion),
        content: Text(tr.delete(item.title)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            child: Text(tr.moveToTrash),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(vaultItemsProvider.notifier).softDeleteItem(item.id);
      if (context.mounted) _showMessage(context, tr.movedToTrash);
    } catch (error) {
      if (context.mounted) _showMessage(context, tr.deletionFailed(error));
    }
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, this.isWarning = false});

  final String label;
  final bool isWarning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isWarning
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: isWarning
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
