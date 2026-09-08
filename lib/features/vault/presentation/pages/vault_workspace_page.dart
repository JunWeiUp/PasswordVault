import 'package:password/core/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:password/features/totp/presentation/widgets/totp_item_card.dart';
import 'package:password/features/vault/presentation/providers/vault_provider.dart';
import 'package:password/features/vault/domain/models/vault_item.dart';
import 'package:uuid/uuid.dart';
import 'package:password/core/extension/extension_helper.dart';
import 'package:password/features/vault/presentation/widgets/password_item_card.dart';
import 'package:password/features/vault/presentation/widgets/crypto_item_card.dart';
import 'package:password/features/vault/presentation/widgets/secure_note_item_card.dart';
import 'package:password/core/utils/import_export_helper.dart';
import 'package:password/features/vault/presentation/providers/master_key_provider.dart';
import 'package:password/features/backup/presentation/providers/backup_provider.dart';
import 'package:password/features/sync/presentation/providers/sync_provider.dart';
import 'package:password/core/providers/app_providers.dart';
import 'package:password/core/widgets/app_components.dart';

final colorLabelMap = <String, Color>{
  tr.red: Colors.red,
  tr.orange: Colors.orange,
  tr.yellow: Colors.amber,
  tr.green: Colors.green,
  tr.blue: Colors.blue,
  tr.purple: Colors.purple,
  tr.pink: Colors.pink,
  tr.cyan: Colors.teal,
};

void _showImportExport(BuildContext context, WidgetRef ref) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    tr.importExport,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.library_add_outlined),
                    title: Text(tr.importMultipleFaEntriesOtpauthUris),
                    subtitle: Text(tr.oneUriPerLineSupportsGoogleAuthenticator),
                    onTap: () {
                      Navigator.pop(context);
                      _showBulkImportDialog(context, ref);
                    },
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.file_download),
                    title: Text(tr.exportAllDataJson),
                    subtitle: Text(tr.unencryptedStoreThisFileSecurely),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      final itemsAsync = ref.read(vaultItemsProvider);
                      final items = itemsAsync.valueOrNull ?? [];
                      if (items.isEmpty) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(tr.noDataToExport)),
                        );
                        return;
                      }
                      final success = await ImportExportHelper.exportToJson(
                        items,
                      );
                      if (success) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(tr.exportComplete)),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.table_view),
                    title: Text(tr.exportCsv),
                    subtitle: Text(tr.forMigrationToAnotherPasswordManager),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      final itemsAsync = ref.read(vaultItemsProvider);
                      final items = itemsAsync.valueOrNull ?? [];
                      if (items.isEmpty) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(tr.noDataToExport)),
                        );
                        return;
                      }
                      final success = await ImportExportHelper.exportToCsv(
                        items,
                      );
                      if (success) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(tr.csvExported)),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.enhanced_encryption),
                    title: Text(tr.exportEncryptedDataJson),
                    subtitle: Text(tr.encryptWithYourMasterPassword),
                    onTap: () async {
                      Navigator.pop(context);
                      final items =
                          ref.read(vaultItemsProvider).valueOrNull ?? [];
                      if (items.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr.noDataToExport)),
                        );
                        return;
                      }

                      final masterPassword = ref
                          .read(masterPasswordProvider)
                          .password;
                      final encryptionService = ref.read(
                        encryptionServiceProvider,
                      );

                      final success = await ImportExportHelper.exportToJson(
                        items,
                        masterPassword: masterPassword,
                        encryptionService: encryptionService,
                      );
                      if (success) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(tr.encryptedDataExported)),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock),
                    title: Text(tr.exportEncryptedCsv),
                    subtitle: Text(tr.encryptedCsvInABaseEnvelope),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      final items =
                          ref.read(vaultItemsProvider).valueOrNull ?? [];
                      if (items.isEmpty) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(tr.noDataToExport)),
                        );
                        return;
                      }

                      final masterPassword = ref
                          .read(masterPasswordProvider)
                          .password;
                      final encryptionService = ref.read(
                        encryptionServiceProvider,
                      );

                      final success = await ImportExportHelper.exportToCsv(
                        items,
                        masterPassword: masterPassword,
                        encryptionService: encryptionService,
                        encrypted: true,
                      );
                      if (success) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(tr.encryptedCsvExported)),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.file_upload),
                    title: Text(tr.importDataJson),
                    subtitle: Text(tr.supportsEncryptedAndUnencryptedFiles),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        final masterKey = await ref.read(
                          masterKeyProvider.future,
                        );
                        final masterPassword = ref
                            .read(masterPasswordProvider)
                            .password;
                        final encryptionService = ref.read(
                          encryptionServiceProvider,
                        );

                        final importedItems =
                            await ImportExportHelper.importFromJson(
                              masterKey: masterKey,
                              masterPassword: masterPassword,
                              encryptionService: encryptionService,
                            );

                        if (importedItems != null && importedItems.isNotEmpty) {
                          await _handleImportMergeResult(
                            messenger,
                            ref,
                            importedItems,
                            sourceLabel: 'JSON',
                          );
                        }
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tr.importFailed(e)),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.lock_open),
                    title: Text(tr.importEncryptedCsv),
                    subtitle: Text(tr.readAnEncryptedCsvExport),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        final masterPassword = ref
                            .read(masterPasswordProvider)
                            .password;
                        if (masterPassword == null || masterPassword.isEmpty) {
                          messenger.showSnackBar(
                            SnackBar(content: Text(tr.unlockYourVaultFirst)),
                          );
                          return;
                        }
                        final encryptionService = ref.read(
                          encryptionServiceProvider,
                        );
                        final importedItems =
                            await ImportExportHelper.importFromEncryptedCsv(
                              masterPassword: masterPassword,
                              encryptionService: encryptionService,
                            );
                        if (importedItems != null && importedItems.isNotEmpty) {
                          await _handleImportMergeResult(
                            messenger,
                            ref,
                            importedItems,
                            sourceLabel: tr.encryptedCsv,
                          );
                        }
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tr.importFailed(e)),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: Text(tr.importLastpassDataCsv),
                    subtitle: Text(tr.readACsvExportFromLastpass),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        final importedItems =
                            await ImportExportHelper.importFromLastPassCsv();

                        if (importedItems != null && importedItems.isNotEmpty) {
                          await _handleImportMergeResult(
                            messenger,
                            ref,
                            importedItems,
                            sourceLabel: 'LastPass',
                          );
                        }
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tr.importFailed(e)),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: Text(tr.importBitwardenDataCsv),
                    subtitle: Text(tr.readACsvExportFromBitwarden),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        final importedItems =
                            await ImportExportHelper.importFromBitwardenCsv();
                        if (importedItems != null && importedItems.isNotEmpty) {
                          await _handleImportMergeResult(
                            messenger,
                            ref,
                            importedItems,
                            sourceLabel: 'Bitwarden',
                          );
                        }
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tr.importFailed(e)),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: Text(tr.importPasswordDataCsv),
                    subtitle: Text(tr.readACsvExportFromPassword),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        final importedItems =
                            await ImportExportHelper.importFrom1PasswordCsv();
                        if (importedItems != null && importedItems.isNotEmpty) {
                          await _handleImportMergeResult(
                            messenger,
                            ref,
                            importedItems,
                            sourceLabel: '1Password',
                          );
                        }
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tr.importFailed(e)),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: Text(tr.importChromePasswordsCsv),
                    subtitle: Text(tr.readACsvExportFromChrome),
                    onTap: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      Navigator.pop(context);
                      try {
                        final importedItems =
                            await ImportExportHelper.importFromChromeCsv();
                        if (importedItems != null && importedItems.isNotEmpty) {
                          await _handleImportMergeResult(
                            messenger,
                            ref,
                            importedItems,
                            sourceLabel: 'Chrome',
                          );
                        }
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(tr.importFailed(e)),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _handleImportMergeResult(
  ScaffoldMessengerState messenger,
  WidgetRef ref,
  List<VaultItem> importedItems, {
  String? sourceLabel,
}) async {
  if (importedItems.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(tr.noDataToImport)));
    return;
  }

  final result = await ref
      .read(vaultItemsProvider.notifier)
      .mergeImportedItems(importedItems);
  final message = tr.importCompleteAddedUpdatedSkipped(
    sourceLabel ?? tr.labelImport,
    result.added,
    result.updated,
    result.skipped,
  );
  messenger.showSnackBar(SnackBar(content: Text(message)));
}

void _showBulkImportDialog(BuildContext context, WidgetRef ref) {
  final controller = TextEditingController();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr.importMultipleFaEntries),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr.pasteOtpauthLinksOnePerLine,
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText:
                  'otpauth://totp/Google:user@gmail.com?secret=JBSWY3DPEHPK3PXP...',
              border: OutlineInputBorder(),
              hintStyle: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr.cancel),
        ),
        ElevatedButton(
          onPressed: () {
            final lines = controller.text.split('\n');
            int successCount = 0;
            for (var line in lines) {
              if (line.trim().isEmpty) continue;
              try {
                final uri = Uri.parse(line.trim());
                if (uri.scheme == 'otpauth' && uri.host == 'totp') {
                  final secret = uri.queryParameters['secret'];
                  final issuer =
                      uri.queryParameters['issuer'] ??
                      (uri.pathSegments.isNotEmpty
                          ? uri.pathSegments[0].split(':').first
                          : 'Unknown');
                  final account = uri.pathSegments.isNotEmpty
                      ? (uri.pathSegments[0].contains(':')
                            ? uri.pathSegments[0].split(':').last
                            : uri.pathSegments[0])
                      : '';

                  if (secret != null) {
                    final newItem = VaultItem(
                      id: const Uuid().v4(),
                      type: VaultItemType.totp,
                      title: Uri.decodeComponent(issuer),
                      username: Uri.decodeComponent(account),
                      secret: secret,
                    );
                    ref.read(vaultItemsProvider.notifier).addItem(newItem);
                    successCount++;
                  }
                }
              } catch (e) {
                // 忽略解析失败的行
              }
            }
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(tr.importedFaEntries(successCount))),
            );
          },
          child: Text(tr.labelImport),
        ),
      ],
    ),
  );
}

void _showAddItemDialog(
  BuildContext context,
  WidgetRef ref,
  VaultItemType type,
) {
  final titleController = TextEditingController();
  final usernameController = TextEditingController();
  final secretOrPasswordController = TextEditingController();
  final urlController = TextEditingController();

  String? selectedVaultId = ref.read(selectedSharedVaultIdProvider);

  showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final sharedVaultsAsync = ref.watch(sharedVaultsProvider);

        return AlertDialog(
          title: Text(
            type == VaultItemType.totp
                ? tr.addFaCode
                : tr.addAccountCredentials,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(labelText: tr.nameEGGoogleGithub),
                ),
                TextField(
                  controller: usernameController,
                  decoration: InputDecoration(labelText: tr.usernameEmail),
                ),
                TextField(
                  controller: secretOrPasswordController,
                  decoration: InputDecoration(
                    labelText: type == VaultItemType.totp
                        ? tr.secretKey
                        : tr.password,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      tooltip: tr.copy,
                      onPressed: () {
                        if (secretOrPasswordController.text.isNotEmpty) {
                          Clipboard.setData(
                            ClipboardData(
                              text: secretOrPasswordController.text,
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(tr.contentsCopiedToClipboard),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  obscureText: type == VaultItemType.password,
                ),
                if (type == VaultItemType.password)
                  TextField(
                    controller: urlController,
                    decoration: InputDecoration(
                      labelText: tr.websitesDomainsCommaSeparated,
                      hintText: 'example.com, example.net',
                    ),
                  ),
                const SizedBox(height: 16),
                // 存放位置选择
                sharedVaultsAsync.when(
                  data: (vaults) {
                    if (vaults.isEmpty) return const SizedBox.shrink();

                    String vaultName = tr.personalVault;
                    if (selectedVaultId != null) {
                      try {
                        vaultName = vaults
                            .firstWhere((v) => v.id == selectedVaultId)
                            .name;
                      } catch (_) {
                        selectedVaultId = null;
                      }
                    }

                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_shared_outlined),
                      title: Text(
                        tr.saveLocation,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        vaultName,
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(Icons.arrow_drop_down),
                      onTap: () {
                        showModalBottomSheet(
                          context: context,
                          builder: (context) => SafeArea(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ListTile(
                                  leading: const Icon(Icons.person_outline),
                                  title: Text(tr.personalVaultDefault),
                                  trailing: selectedVaultId == null
                                      ? const Icon(
                                          Icons.check,
                                          color: Colors.blue,
                                        )
                                      : null,
                                  onTap: () {
                                    setState(() => selectedVaultId = null);
                                    Navigator.pop(context);
                                  },
                                ),
                                ...vaults.map(
                                  (v) => ListTile(
                                    leading: const Icon(
                                      Icons.folder_shared_outlined,
                                    ),
                                    title: Text(v.name),
                                    trailing: selectedVaultId == v.id
                                        ? const Icon(
                                            Icons.check,
                                            color: Colors.blue,
                                          )
                                        : null,
                                    onTap: () {
                                      setState(() => selectedVaultId = v.id);
                                      Navigator.pop(context);
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr.cancel),
            ),
            ElevatedButton(
              onPressed: () {
                if (titleController.text.isEmpty ||
                    secretOrPasswordController.text.isEmpty) {
                  return;
                }

                final newItem = VaultItem(
                  id: const Uuid().v4(),
                  type: type,
                  title: titleController.text,
                  username: usernameController.text,
                  secret: type == VaultItemType.totp
                      ? secretOrPasswordController.text
                      : null,
                  password: type == VaultItemType.password
                      ? secretOrPasswordController.text
                      : null,
                  url: urlController.text.isEmpty ? null : urlController.text,
                  sharedVaultId: selectedVaultId,
                );

                final messenger = ScaffoldMessenger.of(context);
                Navigator.pop(context);
                ref
                    .read(vaultItemsProvider.notifier)
                    .addItem(newItem)
                    .then((_) {
                      messenger.showSnackBar(SnackBar(content: Text(tr.saved)));
                    })
                    .catchError((e) {
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(tr.couldNotSave(e)),
                          backgroundColor: Colors.red,
                        ),
                      );
                    });
              },
              child: Text(tr.save),
            ),
          ],
        );
      },
    ),
  );
}

class MainNavigationScreen extends ConsumerStatefulWidget {
  final String? filterVaultId;
  const MainNavigationScreen({this.filterVaultId, super.key});

  @override
  ConsumerState<MainNavigationScreen> createState() =>
      _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _pendingCheckCurrentTab = false;
  bool _pendingHandleActiveContext = false;
  bool _skipPendingSavePromptForActiveContext = false;

  @override
  void initState() {
    super.initState();
    _searchController.text = ref.read(searchQueryProvider);
    if (widget.filterVaultId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedSharedVaultIdProvider.notifier).state =
            widget.filterVaultId;
      });
    }
    if (ExtensionHelper.isExtension) {
      _pendingCheckCurrentTab = true;
      _pendingHandleActiveContext = true;
      _checkPendingSaves();
      _tryRunPendingExtensionChecks();
    }
  }

  @override
  void didUpdateWidget(MainNavigationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.filterVaultId != oldWidget.filterVaultId &&
        widget.filterVaultId != null) {
      ref.read(selectedSharedVaultIdProvider.notifier).state =
          widget.filterVaultId;
    }
  }

  void _tryRunPendingExtensionChecks() {
    debugPrint('🔍 Trying run pending extension checks...');
    final vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is AsyncData<List<VaultItem>>) {
      debugPrint('✅ Vault items already loaded, running pending checks');
      if (_pendingCheckCurrentTab) {
        _pendingCheckCurrentTab = false;
        _checkCurrentTabMatch();
      }
      if (_pendingHandleActiveContext) {
        _pendingHandleActiveContext = false;
        _handleActiveContext();
      }
    } else {
      debugPrint(
        '⏳ Vault items not yet loaded (state: ${vaultItemsAsync.runtimeType}), waiting for listener',
      );
    }
  }

  Future<void> _checkCurrentTabMatch() async {
    debugPrint('🔍 Starting _checkCurrentTabMatch...');
    final url = await ExtensionHelper.getCurrentTabUrl();
    debugPrint('🌐 Current tab URL: $url');
    if (url == null || url.isEmpty) {
      debugPrint('ℹ️ URL is empty, skipping match check');
      return;
    }

    final host = _extractHost(url);
    debugPrint('🏠 Extracted host: $host');
    if (host.isEmpty) {
      debugPrint('ℹ️ Host is empty, skipping match check');
      return;
    }

    debugPrint('🌐 Current tab host: $host');

    // Wait for vault items to be loaded
    final vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
      debugPrint('⏳ Waiting for vault items to load...');
      // Listen for data to be ready
      ref.listen<AsyncValue<List<VaultItem>>>(vaultItemsProvider, (
        previous,
        next,
      ) {
        if (next is AsyncData<List<VaultItem>> && mounted) {
          _performTabMatch(url, host);
        }
      });
      return;
    }

    await _performTabMatch(url, host);
  }

  Future<void> _performTabMatch(String url, String host) async {
    if (!mounted) return;

    final vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
      debugPrint(
        '⏳ Vault items not in AsyncData state (current: ${vaultItemsAsync.runtimeType})',
      );
      return;
    }

    final items = vaultItemsAsync.valueOrNull ?? [];
    debugPrint('📦 Checking against ${items.length} vault items');
    final matchingItems = items.where((item) {
      if (item.url == null || item.url!.isEmpty) return false;
      return _hostMatches(item.url, url);
    }).toList();

    if (matchingItems.isNotEmpty) {
      debugPrint('🎯 Found ${matchingItems.length} matches for current tab');
      if (mounted) {
        // 切换到“帐号”标签页 (index 1)
        debugPrint('🔄 Switching to account tab and clearing filters');
        ref.read(selectedTabProvider.notifier).state = 1;

        // 清除分类过滤器，显示该站点的所有账号
        ref.read(selectedCategoryProvider.notifier).state = null;

        // 直接搜索域名，显示所有匹配项
        debugPrint('🔍 Setting search query to host: $host');
        ref.read(isSearchingProvider.notifier).state = true;
        ref.read(searchQueryProvider.notifier).state = host;
        _searchController.text = host;
      }
    } else {
      debugPrint('ℹ️ No matching items found for host: $host');
    }
  }

  Future<void> _handleActiveContext() async {
    debugPrint('🔍 Checking for active context from extension...');

    // Wait a bit for UI to be ready
    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    final contextData = await ExtensionHelper.getActiveContext();

    // If no active context, check current tab for matches
    if (contextData == null) {
      debugPrint('ℹ️ No active context found, checking current tab...');
      await _checkCurrentTabMatch();
      return;
    }

    final origin = contextData['origin'] as String?;
    final type = contextData['type'] as String?;

    debugPrint('📦 Active context: type=$type, origin=$origin');

    if (origin == null && type != 'mismatch_detected') {
      // If no origin but has context, still check current tab
      debugPrint('ℹ️ No origin in context, checking current tab...');
      await _checkCurrentTabMatch();
      return;
    }

    debugPrint('🎯 Handling active context: $type for origin: $origin');

    if (type == 'mismatch_detected') {
      final mismatchData = contextData['data'] as Map<Object?, Object?>?;
      if (mismatchData == null) return;

      final url = mismatchData['url'] as String?;
      final username = mismatchData['username'] as String?;
      final password = mismatchData['password'] as String?;
      final reason = mismatchData['reason'] as String?;

      debugPrint('⚠️ Mismatch detected context: $reason for $username at $url');

      final vaultItemsAsync = ref.read(vaultItemsProvider);
      if (vaultItemsAsync is! AsyncData<List<VaultItem>>) return;
      final vaultItems = vaultItemsAsync.valueOrNull ?? [];

      // Find matching item
      final matches = vaultItems
          .where(
            (item) =>
                item.type == VaultItemType.password &&
                _hostMatches(item.url, url ?? ''),
          )
          .toList();

      final exactMatch = matches
          .where((m) => m.username == username)
          .firstOrNull;

      if (!mounted) return;

      if (exactMatch != null) {
        debugPrint('✅ Found exact match for mismatch, navigating to edit...');
        ref.read(selectedTabProvider.notifier).state = 1;
        // Create updated item with the new password
        final updatedItem = exactMatch.copyWith(password: password);
        _skipPendingSavePromptForActiveContext = true;
        context.push('/add-account', extra: updatedItem);
      } else {
        debugPrint('➕ No exact match for mismatch, navigating to add...');
        ref.read(selectedTabProvider.notifier).state = 1;
        _skipPendingSavePromptForActiveContext = true;
        context.push(
          '/add-account',
          extra: VaultItem(
            id: '',
            type: VaultItemType.password,
            title: _extractHost(url),
            username: username ?? '',
            password: password ?? '',
            url: url,
          ),
        );
      }

      await ExtensionHelper.clearActiveContext();
      return;
    }

    if (origin == null) return;

    final fillRequested = contextData['fillRequested'] == true;
    final autoClose = contextData['autoClose'] == true;
    final fillTarget = contextData['fillTarget'] as String?;

    // Wait for vault items to be loaded if needed
    var vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
      debugPrint('⏳ Waiting for vault items to load...');
      await Future.delayed(const Duration(milliseconds: 500));
      vaultItemsAsync = ref.read(vaultItemsProvider);
      if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
        debugPrint(
          '⚠️ Vault items still not loaded, skipping context handling',
        );
        return;
      }
    }

    final vaultItems = vaultItemsAsync.valueOrNull ?? [];

    // Find matching items for this origin
    final matches = vaultItems
        .where(
          (item) =>
              item.type == VaultItemType.password &&
              _hostMatches(item.url, origin),
        )
        .toList();

    if (!mounted) return;

    // Handle fillTarget: 'current_password' — fill only the current password field
    if (fillTarget == 'current_password' && matches.isNotEmpty) {
      final match = matches.first;
      debugPrint('🔑 Filling current password for change-password form');
      await ExtensionHelper.fillCredentials(
        match.username,
        match.password ?? '',
      );
      await ExtensionHelper.clearActiveContext();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(tr.currentPasswordFilled),
            duration: const Duration(seconds: 1),
          ),
        );
        if (autoClose) {
          Future.delayed(const Duration(milliseconds: 500), () {
            ExtensionHelper.closeWindow();
          });
        }
      }
      return;
    }

    // Auto-fill from context menu or inline dropdown
    if (fillRequested && contextData['username'] != null) {
      final targetUsername = contextData['username'] as String;
      final exactMatch = matches
          .where((m) => m.username == targetUsername)
          .firstOrNull;
      if (exactMatch != null) {
        debugPrint('🎯 Auto-filling for: $targetUsername');
        await ExtensionHelper.fillCredentials(
          exactMatch.username,
          exactMatch.password ?? '',
        );
        await ExtensionHelper.clearActiveContext();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tr.credentialsFilled),
              duration: const Duration(seconds: 1),
            ),
          );
          if (autoClose) {
            Future.delayed(const Duration(milliseconds: 500), () {
              ExtensionHelper.closeWindow();
            });
          } else {
            Future.delayed(const Duration(milliseconds: 800), () {
              if (mounted) Navigator.of(context).maybePop();
            });
          }
        }
        return;
      }
    }

    if (matches.isNotEmpty) {
      debugPrint(
        '✅ Found ${matches.length} matching items, navigating to account page with search...',
      );
      ref.read(selectedTabProvider.notifier).state = 1;

      await Future.delayed(const Duration(milliseconds: 100));

      if (!mounted) return;

      final host = _extractHost(origin);
      if (host.isNotEmpty) {
        debugPrint('🔍 Setting search query: $host');
        ref.read(isSearchingProvider.notifier).state = true;
        ref.read(searchQueryProvider.notifier).state = host;
        _searchController.text = host;

        ref.read(selectedCategoryProvider.notifier).state = null;

        debugPrint(
          '✅ Successfully navigated to account page with search: $host',
        );
      }
    } else {
      debugPrint('➕ No matching items, navigating to add...');
      ref.read(selectedTabProvider.notifier).state = 1;
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        _skipPendingSavePromptForActiveContext = true;
        context.push(
          '/add-account',
          extra: VaultItem(
            id: '',
            type: VaultItemType.password,
            title: origin.split('//').last,
            username: contextData['username'] ?? '',
            url: contextData['url'],
          ),
        );
      }
    }

    // Clear context so it doesn't trigger again on next open
    await ExtensionHelper.clearActiveContext();
  }

  Future<void> _checkPendingSaves() async {
    final pending = await ExtensionHelper.getPendingSaves();
    if (pending.isEmpty || !mounted) return;

    final contextData = await ExtensionHelper.getActiveContext();
    final mismatchData = contextData?['data'] as Map<Object?, Object?>?;
    final activeUrl =
        (mismatchData?['url'] ??
                contextData?['url'] ??
                contextData?['origin'] ??
                await ExtensionHelper.getCurrentTabUrl())
            ?.toString();

    if (activeUrl == null || _extractHost(activeUrl).isEmpty) {
      debugPrint(
        'ℹ️ Skipping pending save prompt because active URL is unavailable',
      );
      return;
    }

    final relatedPending = pending.where((item) {
      final pendingUrl = item['url']?.toString();
      return pendingUrl != null && _hostMatches(pendingUrl, activeUrl);
    }).toList();

    if (relatedPending.isEmpty) {
      debugPrint(
        'ℹ️ No pending saves related to current domain: ${_extractHost(activeUrl)}',
      );
      return;
    }

    final first = relatedPending.first;

    // Delay to ensure UI is ready
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      if (_skipPendingSavePromptForActiveContext) {
        debugPrint(
          'ℹ️ Skipping pending save prompt because active context opened account form',
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr.accountReadyToSave(first['username'])),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: tr.saveNow,
            onPressed: () {
              _showPendingSaveDialog(first);
            },
          ),
        ),
      );
    });
  }

  void _showPendingSaveDialog(Map<String, dynamic> data) {
    final titleController = TextEditingController(
      text: data['url']?.split('//').last.split('/').first ?? '',
    );
    final usernameController = TextEditingController(text: data['username']);
    final passwordController = TextEditingController(text: data['password']);
    final urlController = TextEditingController(text: data['url']);
    final existingMatch = _findBestMatchForPending(data);
    final isUpdate = existingMatch != null;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isUpdate ? tr.updateSavedAccount : tr.saveNewAccount),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isUpdate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    tr.anAccountAlreadyExistsForThisWebsite,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: tr.name),
              ),
              TextField(
                controller: usernameController,
                decoration: InputDecoration(labelText: tr.username),
              ),
              TextField(
                controller: passwordController,
                decoration: InputDecoration(labelText: tr.password),
                obscureText: true,
              ),
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: tr.websitesDomains,
                  hintText: tr.separateMultipleDomainsWithCommasOrSemicolons,
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await ExtensionHelper.removePendingSave(data);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(tr.ignore),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                if (isUpdate) {
                  final updatedItem = _mergePendingIntoItem(
                    existingMatch,
                    titleController.text,
                    usernameController.text,
                    passwordController.text,
                    urlController.text,
                  );
                  await ref
                      .read(vaultItemsProvider.notifier)
                      .updateItem(updatedItem);
                } else {
                  final newItem = VaultItem(
                    id: const Uuid().v4(),
                    type: VaultItemType.password,
                    title: titleController.text,
                    username: usernameController.text,
                    password: passwordController.text,
                    url: urlController.text,
                  );
                  await ref.read(vaultItemsProvider.notifier).addItem(newItem);
                }
                await ExtensionHelper.removePendingSave(data);
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        isUpdate ? tr.passwordUpdated : tr.savedToVault,
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(tr.couldNotSave(e)),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(isUpdate ? tr.updatePassword : tr.save),
          ),
        ],
      ),
    );
  }

  VaultItem? _findBestMatchForPending(Map<String, dynamic> data) {
    final vaultItems = ref.read(vaultItemsProvider).valueOrNull ?? [];
    final url = data['url']?.toString();
    final username = data['username']?.toString() ?? '';
    if (url == null || url.isEmpty) return null;

    final matches = vaultItems.where((item) {
      return item.type == VaultItemType.password && _hostMatches(item.url, url);
    }).toList();

    if (matches.isEmpty) return null;
    if (username.isNotEmpty) {
      final exact = matches
          .where((item) => item.username == username)
          .firstOrNull;
      if (exact != null) return exact;
    }
    return null;
  }

  VaultItem _mergePendingIntoItem(
    VaultItem existing,
    String title,
    String username,
    String password,
    String url,
  ) {
    return VaultItem(
      id: existing.id,
      type: existing.type,
      title: title.isNotEmpty ? title : existing.title,
      username: username.isNotEmpty ? username : existing.username,
      password: password.isNotEmpty ? password : existing.password,
      secret: existing.secret,
      mnemonic: existing.mnemonic,
      privateKey: existing.privateKey,
      address: existing.address,
      network: existing.network,
      period: existing.period,
      isFavorite: existing.isFavorite,
      url: url.isNotEmpty ? url : existing.url,
      note: existing.note,
      category: existing.category,
      email: existing.email,
      passwordHistory: existing.passwordHistory,
      accounts: existing.accounts,
      passwordLastChanged: existing.passwordLastChanged,
      passwordDuration: existing.passwordDuration,
      tags: existing.tags,
      sharedVaultId: existing.sharedVaultId,
    );
  }

  String _extractHost(String? url) {
    if (url == null || url.trim().isEmpty) return '';

    // 如果包含多个 URL/域名，取第一个作为主域名（用于标题生成或匹配基准）
    final firstUrl = url.split(RegExp(r'[,\n;]')).first.trim();
    if (firstUrl.isEmpty) return '';

    final trimmed = firstUrl;
    if (!trimmed.contains('://')) {
      final noPath = trimmed.split('/').first;
      return noPath.toLowerCase();
    }
    try {
      return Uri.parse(trimmed).host.toLowerCase();
    } catch (_) {
      return trimmed.toLowerCase();
    }
  }

  bool _hostMatches(String? itemUrl, String originOrUrl) {
    if (itemUrl == null || itemUrl.trim().isEmpty) return false;

    // 支持多个域名/URL
    final itemUrls = itemUrl
        .split(RegExp(r'[,\n;]'))
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty);
    final originHost = _extractHost(originOrUrl);

    for (final rawUrl in itemUrls) {
      final itemHost = _extractHost(rawUrl);
      if (itemHost.isEmpty) {
        if (rawUrl.toLowerCase().contains(originOrUrl.toLowerCase()))
          return true;
        continue;
      }

      if (originHost.isEmpty) {
        if (rawUrl.toLowerCase().contains(originOrUrl.toLowerCase()))
          return true;
        continue;
      }

      if (itemHost == originHost ||
          itemHost.endsWith('.$originHost') ||
          originHost.endsWith('.$itemHost')) {
        return true;
      }
    }

    return false;
  }

  void _showSortMenu(BuildContext context, WidgetRef ref) {
    final current = ref.read(sortModeProvider);
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                tr.sortBy,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            RadioGroup<SortMode>(
              groupValue: current,
              onChanged: (v) {
                if (v != null) {
                  ref.read(sortModeProvider.notifier).setSortMode(v);
                  Navigator.pop(context);
                }
              },
              child: Column(
                children: [
                  RadioListTile<SortMode>(
                    title: Text(tr.nameAZ),
                    value: SortMode.nameAsc,
                  ),
                  RadioListTile<SortMode>(
                    title: Text(tr.nameZA),
                    value: SortMode.nameDesc,
                  ),
                  RadioListTile<SortMode>(
                    title: Text(tr.recentlyModifiedFirst),
                    value: SortMode.updatedDesc,
                  ),
                  RadioListTile<SortMode>(
                    title: Text(tr.oldestModifiedFirst),
                    value: SortMode.updatedAsc,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchActionBar(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _batchButton(
            context,
            Icons.delete_outline,
            tr.delete179,
            Colors.red,
            () => _batchDelete(context, ref),
          ),
          _batchButton(
            context,
            Icons.push_pin_outlined,
            tr.pin,
            null,
            () => _batchTogglePin(context, ref, true),
          ),
          _batchButton(
            context,
            Icons.push_pin,
            tr.unpin,
            null,
            () => _batchTogglePin(context, ref, false),
          ),
          _batchButton(
            context,
            Icons.label_outline,
            tr.tags,
            null,
            () => _batchAddTag(context, ref),
          ),
          _batchButton(
            context,
            Icons.palette_outlined,
            tr.color,
            null,
            () => _batchSetColor(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _batchButton(
    BuildContext context,
    IconData icon,
    String label,
    Color? color,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 22,
              color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _batchDelete(BuildContext context, WidgetRef ref) async {
    final ids = ref.read(selectedItemIdsProvider);
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.deleteSelected),
        content: Text(tr.moveItemsToTheTrash(ids.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(tr.delete179),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    for (final id in ids) {
      await ref.read(vaultItemsProvider.notifier).softDeleteItem(id);
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr.movedToTrash454(ids.length))));
  }

  Future<void> _batchTogglePin(
    BuildContext context,
    WidgetRef ref,
    bool pin,
  ) async {
    final ids = ref.read(selectedItemIdsProvider);
    if (ids.isEmpty) return;
    final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
    for (final id in ids) {
      final item = items.firstWhere(
        (e) => e.id == id,
        orElse: () => VaultItem(
          id: '',
          type: VaultItemType.password,
          title: '',
          username: '',
        ),
      );
      if (item.id.isNotEmpty && item.isPinned != pin) {
        await ref
            .read(vaultItemsProvider.notifier)
            .updateItem(item.copyWith(isPinned: pin));
      }
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          pin ? tr.pinnedItems(ids.length) : tr.unpinnedItems(ids.length),
        ),
      ),
    );
  }

  Future<void> _batchAddTag(BuildContext context, WidgetRef ref) async {
    final ids = ref.read(selectedItemIdsProvider);
    if (ids.isEmpty) return;
    final tagController = TextEditingController();
    final allTags = ref.read(allTagsProvider);
    String? selectedTag;

    final tag = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(tr.addTag),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (allTags.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: allTags
                      .map(
                        (t) => ChoiceChip(
                          label: Text(t, style: const TextStyle(fontSize: 12)),
                          selected: selectedTag == t,
                          onSelected: (s) {
                            setDialogState(() {
                              selectedTag = s ? t : null;
                              tagController.text = s ? t : '';
                            });
                          },
                        ),
                      )
                      .toList(),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: tagController,
                decoration: InputDecoration(labelText: tr.orEnterANewTag),
                onChanged: (v) => setDialogState(() => selectedTag = null),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, tagController.text.trim()),
              child: Text(tr.add),
            ),
          ],
        ),
      ),
    );
    if (tag == null || tag.isEmpty || !context.mounted) return;
    final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
    for (final id in ids) {
      final item = items.firstWhere(
        (e) => e.id == id,
        orElse: () => VaultItem(
          id: '',
          type: VaultItemType.password,
          title: '',
          username: '',
        ),
      );
      if (item.id.isNotEmpty && !item.tags.contains(tag)) {
        await ref
            .read(vaultItemsProvider.notifier)
            .updateItem(item.copyWith(tags: [...item.tags, tag]));
      }
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr.addedTagToItems(ids.length, tag))),
    );
  }

  Future<void> _batchSetColor(BuildContext context, WidgetRef ref) async {
    final ids = ref.read(selectedItemIdsProvider);
    if (ids.isEmpty) return;
    final color = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr.chooseColorLabel),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _colorOption(ctx, null, tr.none, Colors.grey),
            ...colorLabelMap.entries.map(
              (e) => _colorOption(ctx, e.key, e.key, e.value),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
    for (final id in ids) {
      final item = items.firstWhere(
        (e) => e.id == id,
        orElse: () => VaultItem(
          id: '',
          type: VaultItemType.password,
          title: '',
          username: '',
        ),
      );
      if (item.id.isNotEmpty) {
        await ref
            .read(vaultItemsProvider.notifier)
            .updateItem(item.copyWith(colorLabel: color ?? ''));
      }
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(tr.appliedColorToItems(ids.length))));
  }

  Widget _colorOption(
    BuildContext ctx,
    String? value,
    String label,
    Color color,
  ) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 36 + MediaQuery.textScalerOf(context).scale(14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2),
            ),
            child: value == null
                ? Icon(Icons.block, color: Colors.grey[400], size: 20)
                : null,
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 10)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  static const _types = [
    VaultItemType.totp,
    VaultItemType.password,
    VaultItemType.crypto,
    VaultItemType.secureNote,
  ];
  static const _navigationOrder = [1, 0, 2, 3, 4];
  final _searchFocus = FocusNode();
  final Set<int> _visitedTabs = {1};

  void _selectDestination(int index) {
    // Selection never carries into another collection or Settings.
    ref.read(isMultiSelectProvider.notifier).state = false;
    ref.read(selectedItemIdsProvider.notifier).state = {};
    if (index < 4) {
      final category = ref.read(selectedCategoryProvider);
      final items = ref.read(vaultItemsProvider).valueOrNull ?? <VaultItem>[];
      if (category != null &&
          !items.any(
            (item) => item.type == _types[index] && item.category == category,
          )) {
        ref.read(selectedCategoryProvider.notifier).state = null;
      }
    }
    ref.read(selectedTabProvider.notifier).state = index;
    _searchFocus.unfocus();
  }

  void _addItem(int index) {
    if (index == 0) {
      _showAddItemDialog(context, ref, VaultItemType.totp);
      return;
    }
    context.push(
      '/add-account',
      extra: VaultItem(
        id: '',
        type: _types[index],
        title: '',
        username: '',
        sharedVaultId: ref.read(selectedSharedVaultIdProvider),
      ),
    );
  }

  String _title(int index) =>
      [
        tr.accounts,
        tr.codes,
        tr.cryptoAssets,
        tr.secureNotes,
        tr.settings,
      ][index == 0
          ? 1
          : index == 1
          ? 0
          : index];
  String _subtitle(int index) => [
    tr.codesDescription,
    tr.accountsDescription,
    tr.walletsDescription,
    tr.notesDescription,
    tr.settingsDescription,
  ][index];
  String _navLabel(int index) => [
    tr.codes,
    tr.accounts474,
    tr.walletsNav,
    tr.notesNav,
    tr.settings,
  ][index];
  IconData _navIcon(int index) => [
    Icons.timer_outlined,
    Icons.key_outlined,
    Icons.account_balance_wallet_outlined,
    Icons.description_outlined,
    Icons.tune_rounded,
  ][index];

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    if (ExtensionHelper.isExtension) {
      ref.listen<AsyncValue<List<VaultItem>>>(vaultItemsProvider, (_, next) {
        if (next is AsyncData<List<VaultItem>>) _tryRunPendingExtensionChecks();
      });
    }
    ref.watch(syncStatusProvider);
    ref.listen<String>(searchQueryProvider, (_, next) {
      if (_searchController.text != next) {
        _searchController.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });
    final index = ref.watch(selectedTabProvider);
    _visitedTabs.add(index);
    final selecting = ref.watch(isMultiSelectProvider);
    final selectedIds = ref.watch(selectedItemIdsProvider);
    final query = ref.watch(searchQueryProvider);
    final colors = Theme.of(context).colorScheme;
    final count = index < 4
        ? ref.watch(filteredVaultItemsProvider(_types[index])).length
        : 0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final compactSearch =
            MediaQuery.viewInsetsOf(context).bottom > 0 ||
            constraints.maxHeight < 560;
        final content = Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            title: selecting
                ? Text(tr.selected(selectedIds.length))
                : Row(
                    children: [
                      if (!wide) ...[
                        const VaultMark(size: 28),
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          wide ? tr.vaultWorkspace : 'PasswordVault',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
            leading: selecting
                ? IconButton(
                    tooltip: tr.cancel,
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      ref.read(isMultiSelectProvider.notifier).state = false;
                      ref.read(selectedItemIdsProvider.notifier).state = {};
                    },
                  )
                : null,
            actions: [
              if (selecting)
                IconButton(
                  tooltip: tr.selectAll,
                  icon: const Icon(Icons.select_all),
                  onPressed: () {
                    final items = ref.read(
                      filteredVaultItemsProvider(_types[index]),
                    );
                    ref.read(selectedItemIdsProvider.notifier).state = items
                        .map((e) => e.id)
                        .toSet();
                  },
                )
              else ...[
                IconButton(
                  tooltip: tr.passwordGenerator,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  onPressed: () => context.push('/password-generator'),
                ),
                IconButton(
                  tooltip: tr.lockVault,
                  icon: const Icon(Icons.lock_outline),
                  onPressed: () => ref
                      .read(masterPasswordProvider.notifier)
                      .setAuthenticated(false),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!compactSearch)
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          wide ? 32 : 20,
                          20,
                          wide ? 32 : 20,
                          16,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _title(index),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.headlineMedium,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _subtitle(index),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            if (wide && index < 4 && !selecting) ...[
                              const SizedBox(width: 16),
                              FilledButton.icon(
                                onPressed: () => _addItem(index),
                                icon: const Icon(Icons.add, size: 20),
                                label: Text(tr.addItem),
                              ),
                            ],
                          ],
                        ),
                      ),
                    if (index < 4) ...[
                      Padding(
                        key: const ValueKey('vault-search-container'),
                        padding: EdgeInsets.symmetric(
                          horizontal: wide ? 32 : 20,
                        ),
                        child: TextField(
                          key: const ValueKey('vault-search'),
                          controller: _searchController,
                          focusNode: _searchFocus,
                          decoration: InputDecoration(
                            hintText: tr.searchTitlesUsernamesDomains,
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: query.isNotEmpty
                                ? IconButton(
                                    tooltip: tr.clearSearch,
                                    icon: const Icon(Icons.close, size: 20),
                                    onPressed: () {
                                      ref
                                              .read(
                                                searchQueryProvider.notifier,
                                              )
                                              .state =
                                          '';
                                      ref
                                              .read(
                                                isSearchingProvider.notifier,
                                              )
                                              .state =
                                          false;
                                    },
                                  )
                                : null,
                          ),
                          onChanged: (value) {
                            ref.read(searchQueryProvider.notifier).state =
                                value;
                            ref.read(isSearchingProvider.notifier).state =
                                value.isNotEmpty;
                            ref.read(selectedItemIdsProvider.notifier).state =
                                {};
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (!selecting && !compactSearch) ...[
                        const CategoryFilterBar(),
                        const TagFilterBar(),
                        const SharedVaultFilterIndicator(),
                      ],
                      if (!compactSearch)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            wide ? 32 : 20,
                            4,
                            wide ? 24 : 12,
                            0,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  tr.itemsCount(count),
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                ),
                              ),
                              if (!selecting) ...[
                                IconButton(
                                  tooltip: tr.favoritesOnly,
                                  isSelected: ref.watch(
                                    showFavoritesOnlyProvider,
                                  ),
                                  selectedIcon: Icon(
                                    Icons.star_rounded,
                                    color: colors.primary,
                                  ),
                                  icon: const Icon(Icons.star_outline_rounded),
                                  onPressed: () =>
                                      ref
                                          .read(
                                            showFavoritesOnlyProvider.notifier,
                                          )
                                          .state = !ref.read(
                                        showFavoritesOnlyProvider,
                                      ),
                                ),
                                IconButton(
                                  tooltip: tr.sort,
                                  icon: const Icon(Icons.sort_rounded),
                                  onPressed: () => _showSortMenu(context, ref),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: tr.tools,
                                  onSelected: (value) {
                                    if (value == 'select') {
                                      ref
                                              .read(
                                                isMultiSelectProvider.notifier,
                                              )
                                              .state =
                                          true;
                                      ref
                                              .read(
                                                selectedItemIdsProvider
                                                    .notifier,
                                              )
                                              .state =
                                          {};
                                    } else if (value == 'bulk') {
                                      _showBulkImportDialog(context, ref);
                                    } else {
                                      _showImportExport(context, ref);
                                    }
                                  },
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      value: 'select',
                                      child: Text(tr.selectMultiple),
                                    ),
                                    if (index == 0)
                                      PopupMenuItem(
                                        value: 'bulk',
                                        child: Text(tr.bulkImport),
                                      ),
                                    PopupMenuItem(
                                      value: 'import',
                                      child: Text(tr.importAndExport),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                    Expanded(
                      child: IndexedStack(
                        index: index,
                        children: [
                          for (var i = 0; i < 5; i++)
                            if (_visitedTabs.contains(i))
                              TickerMode(
                                enabled: i == index,
                                child: i == 4
                                    ? const SettingsContent()
                                    : VaultListContent(
                                        type: _types[i],
                                        onAdd: () => _addItem(i),
                                      ),
                              )
                            else
                              const SizedBox.shrink(),
                        ],
                      ),
                    ),
                    if (selecting && selectedIds.isNotEmpty)
                      _buildBatchActionBar(context, ref),
                  ],
                ),
              ),
            ),
          ),
          floatingActionButton: !wide && index < 4 && !selecting
              ? FloatingActionButton(
                  tooltip: tr.addItem,
                  onPressed: () => _addItem(index),
                  child: const Icon(Icons.add),
                )
              : null,
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _navigationOrder.indexOf(index),
                  labelBehavior:
                      NavigationDestinationLabelBehavior.onlyShowSelected,
                  onDestinationSelected: (position) =>
                      _selectDestination(_navigationOrder[position]),
                  destinations: [
                    for (final i in _navigationOrder)
                      NavigationDestination(
                        icon: Icon(_navIcon(i)),
                        label: _navLabel(i),
                      ),
                  ],
                ),
        );
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
              if (index < 4) _searchFocus.requestFocus();
            },
            const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () {
              if (index < 4) _searchFocus.requestFocus();
            },
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (selecting) {
                ref.read(isMultiSelectProvider.notifier).state = false;
                ref.read(selectedItemIdsProvider.notifier).state = {};
              } else {
                _searchFocus.unfocus();
              }
            },
          },
          child: Focus(
            autofocus: true,
            child: PopScope(
              canPop: index == 1 && !selecting,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) _selectDestination(1);
              },
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                body: Row(
                  children: [
                    if (wide) _buildSidebar(index),
                    Expanded(child: content),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebar(int index) {
    final colors = Theme.of(context).colorScheme;
    final items = ref.watch(vaultItemsProvider).valueOrNull;
    return Container(
      width: 244,
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 16, 30),
              child: Row(
                children: [
                  const VaultMark(size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'PasswordVault',
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  _sidebarHeading(tr.libraryLabel),
                  for (final i in _navigationOrder.where((i) => i < 4))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        key: ValueKey('nav-$i'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                        ),
                        minVerticalPadding: 10,
                        selected: index == i,
                        selectedTileColor: colors.primaryContainer,
                        selectedColor: colors.onPrimaryContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(_navIcon(i), size: 21),
                        title: Text(_navLabel(i)),
                        trailing: items == null
                            ? null
                            : Text(
                                '${items.where((e) => e.type == _types[i]).length}',
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                        onTap: () => _selectDestination(i),
                      ),
                    ),
                  const SizedBox(height: 24),
                  _sidebarHeading(tr.quickAccess),
                  _sidebarTool(
                    Icons.auto_awesome_outlined,
                    tr.passwordGenerator,
                    '/password-generator',
                  ),
                  _sidebarTool(
                    Icons.verified_user_outlined,
                    tr.checkPasswordHealth,
                    '/security-audit',
                  ),
                  _sidebarTool(
                    Icons.cloud_upload_outlined,
                    tr.webdavBackup,
                    '/backup',
                  ),
                  _sidebarTool(
                    Icons.group_outlined,
                    tr.sharedVaults,
                    '/sharing',
                  ),
                  _sidebarTool(Icons.delete_outline, tr.trash, '/recycle-bin'),
                  const SizedBox(height: 24),
                  ListTile(
                    key: const ValueKey('nav-4'),
                    selected: index == 4,
                    selectedTileColor: colors.primaryContainer,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: const Icon(Icons.tune_rounded),
                    title: Text(tr.settings),
                    onTap: () => _selectDestination(4),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Icon(
                    Icons.science_outlined,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr.developerPreview,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarHeading(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _sidebarTool(IconData icon, String label, String route) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
    minVerticalPadding: 8,
    leading: Icon(icon, size: 20),
    title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    onTap: () => context.push(route),
  );
}

class SharedVaultFilterIndicator extends ConsumerWidget {
  const SharedVaultFilterIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final selectedVaultId = ref.watch(selectedSharedVaultIdProvider);
    if (selectedVaultId == null) return const SizedBox.shrink();

    final sharedVaultsAsync = ref.watch(sharedVaultsProvider);
    return sharedVaultsAsync.when(
      data: (vaults) {
        final vault = vaults.where((v) => v.id == selectedVaultId).firstOrNull;
        if (vault == null) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(
            context,
          ).colorScheme.primaryContainer.withValues(alpha: 0.3),
          child: Row(
            children: [
              const Icon(Icons.people_outline, size: 16),
              const SizedBox(width: 8),
              Text(
                tr.viewingSharedVault(vault.name),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  ref.read(selectedSharedVaultIdProvider.notifier).state = null;
                },
                child: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }
}

class VaultListContent extends ConsumerWidget {
  final VaultItemType type;
  final VoidCallback? onAdd;
  const VaultListContent({required this.type, this.onAdd, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final items = ref.watch(filteredVaultItemsProvider(type));
    final vaultAsync = ref.watch(vaultItemsProvider);
    final isMultiSelect = ref.watch(isMultiSelectProvider);
    final selectedIds = ref.watch(selectedItemIdsProvider);

    return vaultAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => AppEmptyState(
        icon: Icons.cloud_off_outlined,
        title: tr.loadVaultFailed,
        action: FilledButton.tonal(
          onPressed: () => ref.read(vaultItemsProvider.notifier).refresh(),
          child: Text(tr.retryAction),
        ),
      ),
      data: (_) {
        if (items.isEmpty) {
          final isFiltering =
              ref.watch(selectedCategoryProvider) != null ||
              ref.watch(selectedTagProvider) != null ||
              ref.watch(selectedSharedVaultIdProvider) != null ||
              ref.watch(showFavoritesOnlyProvider) ||
              ref.watch(searchQueryProvider).isNotEmpty;

          return AppEmptyState(
            icon: isFiltering
                ? Icons.search_off_rounded
                : Icons.inventory_2_outlined,
            title: isFiltering ? tr.noMatchingItems : tr.noItemsYet,
            message: isFiltering
                ? tr.emptySearchDescription
                : tr.emptyVaultDescription,
            action: isFiltering
                ? TextButton(
                    onPressed: () {
                      ref.read(selectedCategoryProvider.notifier).state = null;
                      ref.read(selectedTagProvider.notifier).state = null;
                      ref.read(selectedSharedVaultIdProvider.notifier).state =
                          null;
                      ref.read(showFavoritesOnlyProvider.notifier).state =
                          false;
                      ref.read(searchQueryProvider.notifier).state = '';
                      ref.read(isSearchingProvider.notifier).state = false;
                    },
                    child: Text(tr.resetFilters),
                  )
                : onAdd == null
                ? null
                : FilledButton.icon(
                    onPressed: onAdd,
                    icon: const Icon(Icons.add),
                    label: Text(tr.addItem),
                  ),
          );
        }

        return ListView.builder(
          key: PageStorageKey(type),
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 96),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final isSelected = selectedIds.contains(item.id);

            Widget card;
            switch (item.type) {
              case VaultItemType.totp:
                card = TotpItemCard(item: item);
                break;
              case VaultItemType.password:
                card = PasswordItemCard(item: item);
                break;
              case VaultItemType.crypto:
                card = CryptoItemCard(item: item);
                break;
              case VaultItemType.secureNote:
                card = SecureNoteItemCard(item: item);
                break;
            }

            if (!isMultiSelect) {
              return _wrapWithColorIndicator(context, item, card);
            }

            return GestureDetector(
              onTap: () {
                final current = Set<String>.from(
                  ref.read(selectedItemIdsProvider),
                );
                if (current.contains(item.id)) {
                  current.remove(item.id);
                } else {
                  current.add(item.id);
                }
                ref.read(selectedItemIdsProvider.notifier).state = current;
              },
              child: Stack(
                children: [
                  AbsorbPointer(
                    child: _wrapWithColorIndicator(context, item, card),
                  ),
                  Positioned(
                    left: 4,
                    top: 12,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isSelected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Colors.grey,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _wrapWithColorIndicator(
    BuildContext context,
    VaultItem item,
    Widget card,
  ) {
    final color = item.colorLabel != null && item.colorLabel!.isNotEmpty
        ? colorLabelMap[item.colorLabel]
        : null;
    if (color == null && !item.isPinned) return card;

    return Stack(
      children: [
        card,
        if (color != null)
          Positioned(
            left: 16,
            top: 8,
            bottom: 8,
            child: Container(
              width: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        if (item.isPinned)
          Positioned(
            right: 20,
            top: 12,
            child: Icon(
              Icons.push_pin,
              size: 14,
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.6),
            ),
          ),
      ],
    );
  }
}

class SettingsContent extends ConsumerWidget {
  const SettingsContent({super.key});

  void _showAutoLockDialog(
    BuildContext context,
    WidgetRef ref,
    int currentMinutes,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.autoLockTimeout),
        content: RadioGroup<int>(
          groupValue: currentMinutes,
          onChanged: (value) {
            if (value != null) {
              ref
                  .read(masterPasswordProvider.notifier)
                  .setAutoLockMinutes(value);
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<int>(title: Text(tr.minute), value: 1),
              RadioListTile<int>(title: Text(tr.minutes), value: 5),
              RadioListTile<int>(title: Text(tr.minutes482), value: 10),
              RadioListTile<int>(title: Text(tr.minutes483), value: 30),
              RadioListTile<int>(title: Text(tr.hour), value: 60),
              RadioListTile<int>(title: Text(tr.hours), value: 240),
            ],
          ),
        ),
      ),
    );
  }

  void _showClearDataDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.deleteAllData),
        content: Text(tr.permanentlyDeleteAllPasswordsSharedVaultsAnd),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await ref.read(vaultItemsProvider.notifier).clearAllData();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(tr.allDataDeleted),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(tr.couldNotDeleteData(e)),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: Text(tr.confirmDeletion490),
          ),
        ],
      ),
    );
  }

  void _showChangeMasterPasswordDialog(BuildContext context, WidgetRef ref) {
    final oldPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final masterState = ref.read(masterPasswordProvider);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.changeMasterPassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPasswordController,
              obscureText: true,
              decoration: InputDecoration(labelText: tr.currentPassword),
            ),
            TextField(
              controller: newPasswordController,
              obscureText: true,
              decoration: InputDecoration(labelText: tr.newPassword),
            ),
            TextField(
              controller: confirmPasswordController,
              obscureText: true,
              decoration: InputDecoration(labelText: tr.confirmNewPassword),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              if (oldPasswordController.text != masterState.password) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr.incorrectCurrentPassword),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              if (newPasswordController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr.newPasswordCannotBeEmpty),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              if (newPasswordController.text !=
                  confirmPasswordController.text) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr.newPasswordsDoNotMatch),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }

              ref
                  .read(masterPasswordProvider.notifier)
                  .setPassword(newPasswordController.text);
              Navigator.pop(context);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(tr.masterPasswordChanged)));
            },
            child: Text(tr.save),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final masterState = ref.watch(masterPasswordProvider);
    final healthReport = ref.watch(passwordHealthProvider);
    final totalIssues =
        healthReport.weakCount +
        healthReport.reusedCount +
        healthReport.expiredCount;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        _buildSection(context, tr.security, [
          ListTile(
            leading: const Icon(Icons.security),
            title: Text(tr.checkPasswordHealth),
            subtitle: Text(
              totalIssues > 0
                  ? tr.issuesFound(totalIssues)
                  : tr.noIssuesDetected,
            ),
            trailing: totalIssues > 0
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$totalIssues',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  )
                : const Icon(Icons.check_circle_outline, color: Colors.green),
            onTap: () => context.push('/security-audit'),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(tr.changeMasterPassword),
            onTap: () => _showChangeMasterPasswordDialog(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: Text(tr.biometricUnlock),
            trailing: Switch(
              value: masterState.isBiometricEnabled,
              onChanged: (v) => ref
                  .read(masterPasswordProvider.notifier)
                  .setBiometricEnabled(v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: Text(tr.autoLock),
            subtitle: Text(tr.minutes504(masterState.autoLockMinutes)),
            onTap: () =>
                _showAutoLockDialog(context, ref, masterState.autoLockMinutes),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(tr.lockVault),
            onTap: () {
              ref.read(masterPasswordProvider.notifier).setAuthenticated(false);
            },
          ),
        ]),
        if (ExtensionHelper.isExtension)
          _buildSection(context, tr.browserExtension, [_AutoFillToggleTile()]),
        _buildSection(context, tr.appearance, [
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(tr.language),
            trailing: const LanguageSelector(),
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(tr.theme),
            subtitle: Text(_themeModeName(ref.watch(themeModeProvider))),
            onTap: () => _showThemeModeDialog(context, ref),
          ),
        ]),
        _buildSection(context, tr.tools, [
          ListTile(
            leading: const Icon(Icons.password),
            title: Text(tr.passwordGenerator),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/password-generator'),
          ),
        ]),
        _buildSection(context, tr.collaborationSharing, [
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: Text(tr.sharedVaultsFamilyTeam),
            subtitle: Text(tr.encryptedSharedFolders),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sharing'),
          ),
        ]),
        _buildSection(context, tr.dataManagement, [
          ListTile(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: Text(tr.webdavBackup),
            subtitle: Text(
              ref.watch(webDavConfigProvider).isValid
                  ? tr.configured
                  : tr.notConfigured,
            ),
            onTap: () => context.push('/backup'),
          ),
          ListTile(
            leading: const Icon(Icons.sync_alt),
            title: Text(tr.localNetworkSync),
            onTap: () => context.push('/local-sync'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(tr.trash),
            onTap: () => context.push('/recycle-bin'),
          ),
          ListTile(
            leading: const Icon(Icons.import_export),
            title: Text(tr.importAndExport),
            onTap: () => _showImportExport(context, ref),
          ),
          ListTile(
            leading: const Icon(
              Icons.delete_forever_outlined,
              color: Colors.red,
            ),
            title: Text(
              tr.deleteAllData,
              style: const TextStyle(color: Colors.red),
            ),
            onTap: () => _showClearDataDialog(context, ref),
          ),
        ]),
        _buildSection(context, tr.about, [
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: Text(tr.previewNotice),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: Text(MaterialLocalizations.of(context).licensesPageTitle),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'PasswordVault',
              applicationVersion: '1.1.0',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(tr.version),
            trailing: const Text('1.1.0'),
          ),
        ]),
      ],
    );
  }

  String _themeModeName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return tr.systemDefault;
      case ThemeMode.light:
        return tr.light;
      case ThemeMode.dark:
        return tr.dark;
    }
  }

  void _showThemeModeDialog(BuildContext context, WidgetRef ref) {
    final current = ref.read(themeModeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.theme),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioGroup<ThemeMode>(
              groupValue: current,
              onChanged: (v) {
                if (v != null) {
                  ref.read(themeModeProvider.notifier).setThemeMode(v);
                  Navigator.pop(context);
                }
              },
              child: Column(
                children: [
                  RadioListTile<ThemeMode>(
                    title: Text(tr.systemDefault),
                    secondary: const Icon(Icons.brightness_auto),
                    value: ThemeMode.system,
                  ),
                  RadioListTile<ThemeMode>(
                    title: Text(tr.lightMode),
                    secondary: const Icon(Icons.light_mode),
                    value: ThemeMode.light,
                  ),
                  RadioListTile<ThemeMode>(
                    title: Text(tr.darkMode),
                    secondary: const Icon(Icons.dark_mode),
                    value: ThemeMode.dark,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    String title,
    List<Widget> children,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
          AppSectionCard(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _AutoFillToggleTile extends StatefulWidget {
  @override
  State<_AutoFillToggleTile> createState() => _AutoFillToggleTileState();
}

class _AutoFillToggleTileState extends State<_AutoFillToggleTile> {
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await ExtensionHelper.getAutoFillEnabled();
    if (mounted)
      setState(() {
        _enabled = v;
        _loaded = true;
      });
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.auto_fix_high),
      title: Text(tr.automaticPageFill),
      subtitle: Text(tr.fillMatchingCredentialsWhenAPageLoads),
      trailing: _loaded
          ? Switch(
              value: _enabled,
              onChanged: (v) async {
                setState(() => _enabled = v);
                await ExtensionHelper.setAutoFillEnabled(v);
              },
            )
          : const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }
}

class CategoryFilterBar extends ConsumerWidget {
  const CategoryFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final index = ref.watch(selectedTabProvider);
    final type = _MainNavigationScreenState._types[index < 4 ? index : 1];
    final categories =
        (ref.watch(vaultItemsProvider).valueOrNull ?? <VaultItem>[])
            .where((item) => item.type == type && item.category != null)
            .map((item) => item.category!)
            .toSet()
            .toList()
          ..sort();
    final selectedCategory = ref.watch(selectedCategoryProvider);

    return Container(
      height: 44 + MediaQuery.textScalerOf(context).scale(16),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _buildCategoryChip(
            context,
            ref,
            tr.all,
            selectedCategory == null,
            () => ref.read(selectedCategoryProvider.notifier).state = null,
            icon: Icons.grid_view_rounded,
          ),
          ...categories.map(
            (category) => _buildCategoryChip(
              context,
              ref,
              category,
              selectedCategory == category,
              () =>
                  ref.read(selectedCategoryProvider.notifier).state = category,
              icon: _getCategoryIcon(category),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChip(
    BuildContext context,
    WidgetRef ref,
    String label,
    bool isSelected,
    VoidCallback onSelected, {
    IconData? icon,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(localizedCategory(label)),
        selected: isSelected,
        onSelected: (_) => onSelected(),
        avatar: icon != null
            ? Icon(
                icon,
                size: 16,
                color: isSelected ? colorScheme.onPrimary : colorScheme.primary,
              )
            : null,
        showCheckmark: false,
        backgroundColor: colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.3,
        ),
        selectedColor: colorScheme.primary,
        labelStyle: TextStyle(
          color: isSelected
              ? colorScheme.onPrimary
              : colorScheme.onSurfaceVariant,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide.none,
        ),
      ),
    );
  }

  IconData _getCategoryIcon(String category) {
    switch (category) {
      case '社交媒体':
        return Icons.share_rounded;
      case '财务':
        return Icons.account_balance_wallet_rounded;
      case '工作':
        return Icons.work_rounded;
      case '购物':
        return Icons.shopping_cart_rounded;
      case '娱乐':
        return Icons.movie_rounded;
      case '加密资产':
        return Icons.currency_bitcoin_rounded;
      case '笔记':
        return Icons.notes_rounded;
      default:
        return Icons.folder_rounded;
    }
  }
}

class TagFilterBar extends ConsumerWidget {
  const TagFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppLocalizations.of(context);
    final tags = ref.watch(allTagsProvider);
    final selectedTag = ref.watch(selectedTagProvider);

    if (tags.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 36 + MediaQuery.textScalerOf(context).scale(14),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(tr.allTags, style: const TextStyle(fontSize: 12)),
              selected: selectedTag == null,
              onSelected: (selected) {
                if (selected) {
                  ref.read(selectedTagProvider.notifier).state = null;
                }
              },
            ),
          ),
          ...tags.map(
            (tag) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(tag, style: const TextStyle(fontSize: 12)),
                selected: selectedTag == tag,
                onSelected: (selected) {
                  ref.read(selectedTagProvider.notifier).state = selected
                      ? tag
                      : null;
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
