import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';
import 'features/totp/presentation/widgets/totp_item_card.dart';
import 'features/vault/presentation/providers/vault_provider.dart';
import 'features/vault/domain/models/vault_item.dart';
import 'package:uuid/uuid.dart';
import 'core/extension/extension_helper.dart';
import 'features/vault/presentation/widgets/password_item_card.dart';
import 'features/vault/presentation/widgets/crypto_item_card.dart';
import 'features/vault/presentation/widgets/secure_note_item_card.dart';
import 'core/utils/import_export_helper.dart';
import 'features/vault/presentation/pages/add_account_page.dart';
import 'features/vault/presentation/pages/password_generator_page.dart';

import 'features/vault/presentation/pages/lock_page.dart';
import 'features/vault/presentation/providers/master_key_provider.dart';
import 'features/backup/presentation/pages/webdav_config_page.dart';
import 'features/backup/presentation/pages/backup_page.dart';
import 'features/backup/presentation/providers/backup_provider.dart';

import 'features/vault/presentation/pages/recycle_bin_page.dart';
import 'features/vault/presentation/pages/security_audit_page.dart';
import 'features/sync/presentation/pages/local_sync_page.dart';
import 'features/sync/presentation/providers/sync_provider.dart';
import 'features/vault/presentation/pages/sharing/shared_vault_list_page.dart';
import 'features/vault/presentation/pages/sharing/create_shared_vault_page.dart';
import 'features/vault/presentation/pages/sharing/share_public_key_page.dart';
import 'features/vault/presentation/pages/sharing/add_member_page.dart';
import 'features/vault/presentation/pages/sharing/shared_vault_details_page.dart';
import 'features/vault/presentation/pages/sharing/lan_discovery_page.dart';

import 'core/providers/app_providers.dart';

// Re-export for backward compatibility
export 'core/providers/app_providers.dart' show searchQueryProvider, selectedTabProvider, isSearchingProvider;

const colorLabelMap = <String, Color>{
  '红色': Colors.red,
  '橙色': Colors.orange,
  '黄色': Colors.amber,
  '绿色': Colors.green,
  '蓝色': Colors.blue,
  '紫色': Colors.purple,
  '粉色': Colors.pink,
  '青色': Colors.teal,
};

// --- Router ---
final _router = GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    // 这里不能直接用 ref，我们需要在 MaterialApp.router 中使用 ProviderScope 的 context
    // 或者使用 refreshListenable。但简单起见，我们可以在 build 中判断。
    // 不过 GoRouter 的 redirect 更好。
    return null;
  },
  routes: [
    GoRoute(
      path: '/lock',
      builder: (context, state) => const LockPage(),
    ),
    GoRoute(
      path: '/backup',
      builder: (context, state) => const AuthGuard(child: BackupPage()),
    ),
    GoRoute(
      path: '/webdav-config',
      builder: (context, state) => const AuthGuard(child: WebDavConfigPage()),
    ),
    GoRoute(
      path: '/recycle-bin',
      builder: (context, state) => const AuthGuard(child: RecycleBinPage()),
    ),
    GoRoute(
      path: '/security-audit',
      builder: (context, state) => const AuthGuard(child: SecurityAuditPage()),
    ),
    GoRoute(
      path: '/local-sync',
      builder: (context, state) => const AuthGuard(child: LocalSyncPage()),
    ),
    GoRoute(
      path: '/sharing',
      builder: (context, state) => const AuthGuard(child: SharedVaultListPage()),
    ),
    GoRoute(
      path: '/sharing/create',
      builder: (context, state) => const AuthGuard(child: CreateSharedVaultPage()),
    ),
    GoRoute(
      path: '/sharing/public-key',
      builder: (context, state) => const AuthGuard(child: SharePublicKeyPage()),
    ),
    GoRoute(
      path: '/sharing/lan-discovery',
      builder: (context, state) => const AuthGuard(child: LanDiscoveryPage()),
    ),
    GoRoute(
      path: '/sharing/add-member/:vaultId',
      builder: (context, state) {
        final vaultId = state.pathParameters['vaultId']!;
        return AuthGuard(child: AddMemberPage(vaultId: vaultId));
      },
    ),
    GoRoute(
      path: '/sharing/details/:vaultId',
      builder: (context, state) {
        final vaultId = state.pathParameters['vaultId']!;
        final vault = state.extra as SharedVault?;
        return AuthGuard(child: SharedVaultDetailsPage(vaultId: vaultId, vault: vault));
      },
    ),
    GoRoute(
      path: '/',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>?;
        final filterVaultId = extra?['filterVaultId'] as String?;
        return AuthGuard(child: MainNavigationScreen(filterVaultId: filterVaultId));
      },
      routes: [
        GoRoute(
          path: 'add-account',
          builder: (context, state) {
            final item = state.extra as VaultItem?;
            return AddAccountPage(item: item);
          },
        ),
        GoRoute(
          path: 'password-generator',
          builder: (context, state) => const PasswordGeneratorPage(),
        ),
      ],
    ),
  ],
);

class AuthGuard extends ConsumerWidget {
  final Widget child;
  const AuthGuard({required this.child, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final masterState = ref.watch(masterPasswordProvider);
    
    if (!masterState.isAuthenticated) {
      return const LockPage();
    }
    
    return child;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Set up global error handling for Dart
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('❌ Flutter Error: ${details.exception}');
    debugPrint('❌ Stack trace: ${details.stack}');
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('❌ Unhandled Platform Error: $error');
    debugPrint('❌ Stack trace: $stack');
    return true;
  };

  runApp(const ProviderScope(child: SecurePassApp()));
}

class SecurePassApp extends ConsumerWidget {
  const SecurePassApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'SecurePass',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}

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
                  const Text(
                    '导入/导出',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
            title: const Text('批量导入 2FA (otpauth URIs)'),
            subtitle: const Text('每行一个 URI，支持 Google Authenticator 格式'),
            onTap: () {
              Navigator.pop(context);
              _showBulkImportDialog(context, ref);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.file_download),
            title: const Text('导出所有数据 (JSON)'),
            subtitle: const Text('未加密，请妥善保管'),
            onTap: () async {
              Navigator.pop(context);
              final itemsAsync = ref.read(vaultItemsProvider);
              final items = itemsAsync.valueOrNull ?? [];
              if (items.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('没有可导出的数据')),
                );
                return;
              }
              final success = await ImportExportHelper.exportToJson(items);
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('导出成功')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.table_view),
            title: const Text('导出 CSV'),
            subtitle: const Text('适合迁移到其他密码管理器'),
            onTap: () async {
              Navigator.pop(context);
              final itemsAsync = ref.read(vaultItemsProvider);
              final items = itemsAsync.valueOrNull ?? [];
              if (items.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('没有可导出的数据')),
                );
                return;
              }
              final success = await ImportExportHelper.exportToCsv(items);
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('CSV 导出成功')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.enhanced_encryption),
            title: const Text('导出加密数据 (JSON)'),
            subtitle: const Text('使用主密码加密，更安全'),
            onTap: () async {
              Navigator.pop(context);
              final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
              if (items.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('没有可导出的数据')),
                );
                return;
              }

              final masterPassword = ref.read(masterPasswordProvider).password;
              final encryptionService = ref.read(encryptionServiceProvider);

              final success = await ImportExportHelper.exportToJson(
                items, 
                masterPassword: masterPassword, 
                encryptionService: encryptionService
              );
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('加密导出成功')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('导出加密 CSV'),
            subtitle: const Text('CSV 内容已加密（base64）'),
            onTap: () async {
              Navigator.pop(context);
              final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
              if (items.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('没有可导出的数据')),
                );
                return;
              }

              final masterPassword = ref.read(masterPasswordProvider).password;
              final encryptionService = ref.read(encryptionServiceProvider);

              final success = await ImportExportHelper.exportToCsv(
                items,
                masterPassword: masterPassword,
                encryptionService: encryptionService,
                encrypted: true,
              );
              if (success) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('加密 CSV 导出成功')),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_upload),
            title: const Text('导入数据 (JSON)'),
            subtitle: const Text('支持加密和非加密格式'),
            onTap: () async {
              Navigator.pop(context);
              try {
                final masterKey = await ref.read(masterKeyProvider.future);
                final masterPassword = ref.read(masterPasswordProvider).password;
                final encryptionService = ref.read(encryptionServiceProvider);

                final importedItems = await ImportExportHelper.importFromJson(
                  masterKey: masterKey,
                  masterPassword: masterPassword,
                  encryptionService: encryptionService,
                );

                if (importedItems != null && importedItems.isNotEmpty) {
                  await _handleImportMergeResult(
                    context,
                    ref,
                    importedItems,
                    sourceLabel: 'JSON',
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock_open),
            title: const Text('导入加密 CSV'),
            subtitle: const Text('解析加密导出的 CSV 文件'),
            onTap: () async {
              Navigator.pop(context);
              try {
                final masterPassword = ref.read(masterPasswordProvider).password;
                if (masterPassword == null || masterPassword.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请先解锁以获取主密码')),
                  );
                  return;
                }
                final encryptionService = ref.read(encryptionServiceProvider);
                final importedItems = await ImportExportHelper.importFromEncryptedCsv(
                  masterPassword: masterPassword,
                  encryptionService: encryptionService,
                );
                if (importedItems != null && importedItems.isNotEmpty) {
                  await _handleImportMergeResult(
                    context,
                    ref,
                    importedItems,
                    sourceLabel: '加密 CSV',
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导入 LastPass 数据 (CSV)'),
            subtitle: const Text('支持从 LastPass 导出的 CSV 文件'),
            onTap: () async {
              Navigator.pop(context);
              try {
                final importedItems = await ImportExportHelper.importFromLastPassCsv();

                if (importedItems != null && importedItems.isNotEmpty) {
                  await _handleImportMergeResult(
                    context,
                    ref,
                    importedItems,
                    sourceLabel: 'LastPass',
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导入 Bitwarden 数据 (CSV)'),
            subtitle: const Text('支持从 Bitwarden 导出的 CSV 文件'),
            onTap: () async {
              Navigator.pop(context);
              try {
                final importedItems = await ImportExportHelper.importFromBitwardenCsv();
                if (importedItems != null && importedItems.isNotEmpty) {
                  await _handleImportMergeResult(
                    context,
                    ref,
                    importedItems,
                    sourceLabel: 'Bitwarden',
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导入 1Password 数据 (CSV)'),
            subtitle: const Text('支持从 1Password 导出的 CSV 文件'),
            onTap: () async {
              Navigator.pop(context);
              try {
                final importedItems = await ImportExportHelper.importFrom1PasswordCsv();
                if (importedItems != null && importedItems.isNotEmpty) {
                  await _handleImportMergeResult(
                    context,
                    ref,
                    importedItems,
                    sourceLabel: '1Password',
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
                );
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导入 Chrome 密码 (CSV)'),
            subtitle: const Text('支持从 Chrome 导出的 CSV 文件'),
            onTap: () async {
              Navigator.pop(context);
              try {
                final importedItems = await ImportExportHelper.importFromChromeCsv();
                if (importedItems != null && importedItems.isNotEmpty) {
                  await _handleImportMergeResult(
                    context,
                    ref,
                    importedItems,
                    sourceLabel: 'Chrome',
                  );
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('导入失败: $e'), backgroundColor: Colors.red),
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
  BuildContext context,
  WidgetRef ref,
  List<VaultItem> importedItems, {
  String sourceLabel = '导入',
}) async {
  if (importedItems.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('没有可导入的数据')),
    );
    return;
  }

  final result = await ref.read(vaultItemsProvider.notifier).mergeImportedItems(importedItems);
  final message = '$sourceLabel 导入完成：新增 ${result.added}，更新 ${result.updated}，跳过 ${result.skipped}';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

void _showBulkImportDialog(BuildContext context, WidgetRef ref) {
  final controller = TextEditingController();
  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('批量导入 2FA'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('请粘贴 otpauth:// 链接，每行一个：', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: 'otpauth://totp/Google:user@gmail.com?secret=JBSWY3DPEHPK3PXP...',
              border: OutlineInputBorder(),
              hintStyle: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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
                  final issuer = uri.queryParameters['issuer'] ?? 
                               (uri.pathSegments.isNotEmpty ? uri.pathSegments[0].split(':').first : 'Unknown');
                  final account = uri.pathSegments.isNotEmpty ? 
                                (uri.pathSegments[0].contains(':') ? uri.pathSegments[0].split(':').last : uri.pathSegments[0]) : '';

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
              SnackBar(content: Text('成功导入 $successCount 个 2FA 项目')),
            );
          },
          child: const Text('导入'),
        ),
      ],
    ),
  );
}

void _showAddItemDialog(BuildContext context, WidgetRef ref, VaultItemType type) {
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
          title: Text(type == VaultItemType.totp ? '添加 2FA 代码' : '添加帐号密码'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: '名称 (如: Google, GitHub)'),
                ),
                TextField(
                  controller: usernameController,
                  decoration: const InputDecoration(labelText: '用户名/邮箱'),
                ),
                TextField(
                  controller: secretOrPasswordController,
                  decoration: InputDecoration(
                    labelText: type == VaultItemType.totp ? '密钥 (Secret Key)' : '密码',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      tooltip: '复制',
                      onPressed: () {
                        if (secretOrPasswordController.text.isNotEmpty) {
                          Clipboard.setData(ClipboardData(text: secretOrPasswordController.text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('内容已复制到剪贴板')),
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
                    decoration: const InputDecoration(
                      labelText: '网站/域名 (支持多个，逗号分隔)',
                      hintText: 'example.com, example.net',
                    ),
                  ),
                const SizedBox(height: 16),
                // 存放位置选择
                sharedVaultsAsync.when(
                  data: (vaults) {
                    if (vaults.isEmpty) return const SizedBox.shrink();
                    
                    String vaultName = '个人库';
                    if (selectedVaultId != null) {
                      try {
                        vaultName = vaults.firstWhere((v) => v.id == selectedVaultId).name;
                      } catch (_) {
                        selectedVaultId = null;
                      }
                    }
                    
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_shared_outlined),
                      title: const Text('存放位置', style: TextStyle(fontSize: 14)),
                      subtitle: Text(vaultName, style: const TextStyle(fontSize: 12)),
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
                                  title: const Text('个人库 (默认)'),
                                  trailing: selectedVaultId == null ? const Icon(Icons.check, color: Colors.blue) : null,
                                  onTap: () {
                                    setState(() => selectedVaultId = null);
                                    Navigator.pop(context);
                                  },
                                ),
                                ...vaults.map((v) => ListTile(
                                  leading: const Icon(Icons.folder_shared_outlined),
                                  title: Text(v.name),
                                  trailing: selectedVaultId == v.id ? const Icon(Icons.check, color: Colors.blue) : null,
                                  onTap: () {
                                    setState(() => selectedVaultId = v.id);
                                    Navigator.pop(context);
                                  },
                                )),
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
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                if (titleController.text.isEmpty || secretOrPasswordController.text.isEmpty) {
                  return;
                }

                final newItem = VaultItem(
                  id: const Uuid().v4(),
                  type: type,
                  title: titleController.text,
                  username: usernameController.text,
                  secret: type == VaultItemType.totp ? secretOrPasswordController.text : null,
                  password: type == VaultItemType.password ? secretOrPasswordController.text : null,
                  url: urlController.text.isEmpty ? null : urlController.text,
                  sharedVaultId: selectedVaultId,
                );

                ref.read(vaultItemsProvider.notifier).addItem(newItem).then((_) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('保存成功')),
                  );
                }).catchError((e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
                  );
                });
                Navigator.pop(context);
              },
              child: const Text('保存'),
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
  ConsumerState<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _pendingCheckCurrentTab = false;
  bool _pendingHandleActiveContext = false;

  @override
  void initState() {
    super.initState();
    if (widget.filterVaultId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedSharedVaultIdProvider.notifier).state = widget.filterVaultId;
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
    if (widget.filterVaultId != oldWidget.filterVaultId && widget.filterVaultId != null) {
      ref.read(selectedSharedVaultIdProvider.notifier).state = widget.filterVaultId;
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
      debugPrint('⏳ Vault items not yet loaded (state: ${vaultItemsAsync.runtimeType}), waiting for listener');
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
      ref.listen<AsyncValue<List<VaultItem>>>(vaultItemsProvider, (previous, next) {
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
      debugPrint('⏳ Vault items not in AsyncData state (current: ${vaultItemsAsync.runtimeType})');
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
      final matches = vaultItems.where((item) => 
        item.type == VaultItemType.password && 
        _hostMatches(item.url, url ?? '')
      ).toList();
      
      final exactMatch = matches.where((m) => m.username == username).firstOrNull;
      
      if (!mounted) return;
      
      if (exactMatch != null) {
        debugPrint('✅ Found exact match for mismatch, navigating to edit...');
        ref.read(selectedTabProvider.notifier).state = 1;
        // Create updated item with the new password
        final updatedItem = exactMatch.copyWith(password: password);
        context.push('/add-account', extra: updatedItem);
      } else {
        debugPrint('➕ No exact match for mismatch, navigating to add...');
        ref.read(selectedTabProvider.notifier).state = 1;
        context.push('/add-account', extra: VaultItem(
          id: '',
          type: VaultItemType.password,
          title: _extractHost(url),
          username: username ?? '',
          password: password ?? '',
          url: url,
        ));
      }
      
      await ExtensionHelper.clearActiveContext();
      return;
    }

    if (origin == null) return;

    final fillRequested = contextData['fillRequested'] == true;

    // Wait for vault items to be loaded if needed
    var vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
      debugPrint('⏳ Waiting for vault items to load...');
      await Future.delayed(const Duration(milliseconds: 500));
      vaultItemsAsync = ref.read(vaultItemsProvider);
      if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
        debugPrint('⚠️ Vault items still not loaded, skipping context handling');
        return;
      }
    }

    final vaultItems = vaultItemsAsync.valueOrNull ?? [];
    
    // Find matching items for this origin
    final matches = vaultItems.where((item) => 
      item.type == VaultItemType.password && 
      _hostMatches(item.url, origin)
    ).toList();

    if (!mounted) return;

    // Auto-fill from right-click context menu
    if (fillRequested && contextData['username'] != null) {
      final targetUsername = contextData['username'] as String;
      final exactMatch = matches.where((m) => m.username == targetUsername).firstOrNull;
      if (exactMatch != null) {
        debugPrint('🎯 Auto-filling from context menu for: $targetUsername');
        await ExtensionHelper.fillCredentials(exactMatch.username, exactMatch.password ?? '');
        await ExtensionHelper.clearActiveContext();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已自动填充'), duration: Duration(seconds: 1)),
          );
          // Close the popup window after a brief delay
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.of(context).maybePop();
          });
        }
        return;
      }
    }

    if (matches.isNotEmpty) {
      debugPrint('✅ Found ${matches.length} matching items, navigating to account page with search...');
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
        
        debugPrint('✅ Successfully navigated to account page with search: $host');
      }
    } else {
      debugPrint('➕ No matching items, navigating to add...');
      ref.read(selectedTabProvider.notifier).state = 1;
      await Future.delayed(const Duration(milliseconds: 100));
      if (mounted) {
        context.push('/add-account', extra: VaultItem(
          id: '',
          type: VaultItemType.password,
          title: origin.split('//').last,
          username: contextData['username'] ?? '',
          url: contextData['url'],
        ));
      }
    }
    
    // Clear context so it doesn't trigger again on next open
    await ExtensionHelper.clearActiveContext();
  }

  Future<void> _checkPendingSaves() async {
    final pending = await ExtensionHelper.getPendingSaves();
    if (pending.isNotEmpty && mounted) {
      final first = pending.first;
      
      // Delay to ensure UI is ready
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('检测到待保存账号: ${first['username']}'),
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: '立即保存',
              onPressed: () {
                _showPendingSaveDialog(first);
              },
            ),
          ),
        );
      });
    }
  }

  void _showPendingSaveDialog(Map<String, dynamic> data) {
    final titleController = TextEditingController(text: data['url']?.split('//').last.split('/').first ?? '');
    final usernameController = TextEditingController(text: data['username']);
    final passwordController = TextEditingController(text: data['password']);
    final urlController = TextEditingController(text: data['url']);
    final existingMatch = _findBestMatchForPending(data);
    final isUpdate = existingMatch != null;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isUpdate ? '更新已保存账号' : '保存新账号'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isUpdate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '检测到该网站已有账号，将更新密码并保留历史记录。',
                    style: TextStyle(color: Theme.of(context).colorScheme.primary),
                  ),
                ),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: usernameController,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              TextField(
                controller: passwordController,
                decoration: const InputDecoration(labelText: '密码'),
                obscureText: true,
              ),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '网站/域名',
                  hintText: '支持多个域名，以逗号或分号分隔',
                ),
                maxLines: 1,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('忽略'),
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
                  await ref.read(vaultItemsProvider.notifier).updateItem(updatedItem);
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
                await ExtensionHelper.clearPendingSaves();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(isUpdate ? '已更新密码' : '已保存到保险箱')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red));
                }
              }
            },
            child: Text(isUpdate ? '更新密码' : '保存'),
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
      final exact = matches.where((item) => item.username == username).firstOrNull;
      if (exact != null) return exact;
    }
    return matches.first;
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
    final itemUrls = itemUrl.split(RegExp(r'[,\n;]')).map((u) => u.trim()).where((u) => u.isNotEmpty);
    final originHost = _extractHost(originOrUrl);
    
    for (final rawUrl in itemUrls) {
      final itemHost = _extractHost(rawUrl);
      if (itemHost.isEmpty) {
        if (rawUrl.toLowerCase().contains(originOrUrl.toLowerCase())) return true;
        continue;
      }

      if (originHost.isEmpty) {
        if (rawUrl.toLowerCase().contains(originOrUrl.toLowerCase())) return true;
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
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('排序方式', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            RadioListTile<SortMode>(
              title: const Text('名称 A → Z'),
              value: SortMode.nameAsc,
              groupValue: current,
              onChanged: (v) {
                ref.read(sortModeProvider.notifier).setSortMode(v!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortMode>(
              title: const Text('名称 Z → A'),
              value: SortMode.nameDesc,
              groupValue: current,
              onChanged: (v) {
                ref.read(sortModeProvider.notifier).setSortMode(v!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortMode>(
              title: const Text('最近修改优先'),
              value: SortMode.updatedDesc,
              groupValue: current,
              onChanged: (v) {
                ref.read(sortModeProvider.notifier).setSortMode(v!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<SortMode>(
              title: const Text('最早修改优先'),
              value: SortMode.updatedAsc,
              groupValue: current,
              onChanged: (v) {
                ref.read(sortModeProvider.notifier).setSortMode(v!);
                Navigator.pop(context);
              },
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
        color: Theme.of(context).colorScheme.surfaceVariant,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 4, offset: const Offset(0, -2))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _batchButton(context, Icons.delete_outline, '删除', Colors.red, () => _batchDelete(context, ref)),
          _batchButton(context, Icons.push_pin_outlined, '置顶', null, () => _batchTogglePin(context, ref, true)),
          _batchButton(context, Icons.push_pin, '取消置顶', null, () => _batchTogglePin(context, ref, false)),
          _batchButton(context, Icons.label_outline, '标签', null, () => _batchAddTag(context, ref)),
          _batchButton(context, Icons.palette_outlined, '颜色', null, () => _batchSetColor(context, ref)),
        ],
      ),
    );
  }

  Widget _batchButton(BuildContext context, IconData icon, String label, Color? color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant)),
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
        title: const Text('批量删除'),
        content: Text('确定要将 ${ids.length} 个项目移至回收站吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    for (final id in ids) {
      await ref.read(vaultItemsProvider.notifier).softDeleteItem(id);
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已将 ${ids.length} 项移至回收站')));
    }
  }

  Future<void> _batchTogglePin(BuildContext context, WidgetRef ref, bool pin) async {
    final ids = ref.read(selectedItemIdsProvider);
    if (ids.isEmpty) return;
    final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
    for (final id in ids) {
      final item = items.firstWhere((e) => e.id == id, orElse: () => VaultItem(id: '', type: VaultItemType.password, title: '', username: ''));
      if (item.id.isNotEmpty && item.isPinned != pin) {
        await ref.read(vaultItemsProvider.notifier).updateItem(item.copyWith(isPinned: pin));
      }
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pin ? '已置顶 ${ids.length} 项' : '已取消置顶 ${ids.length} 项')));
    }
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
          title: const Text('添加标签'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (allTags.isNotEmpty)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: allTags.map((t) => ChoiceChip(
                    label: Text(t, style: const TextStyle(fontSize: 12)),
                    selected: selectedTag == t,
                    onSelected: (s) {
                      setDialogState(() {
                        selectedTag = s ? t : null;
                        tagController.text = s ? t : '';
                      });
                    },
                  )).toList(),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: tagController,
                decoration: const InputDecoration(labelText: '或输入新标签'),
                onChanged: (v) => setDialogState(() => selectedTag = null),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, tagController.text.trim()), child: const Text('添加')),
          ],
        ),
      ),
    );
    if (tag == null || tag.isEmpty || !mounted) return;
    final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
    for (final id in ids) {
      final item = items.firstWhere((e) => e.id == id, orElse: () => VaultItem(id: '', type: VaultItemType.password, title: '', username: ''));
      if (item.id.isNotEmpty && !item.tags.contains(tag)) {
        await ref.read(vaultItemsProvider.notifier).updateItem(item.copyWith(tags: [...item.tags, tag]));
      }
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已为 ${ids.length} 项添加标签"$tag"')));
    }
  }

  Future<void> _batchSetColor(BuildContext context, WidgetRef ref) async {
    final ids = ref.read(selectedItemIdsProvider);
    if (ids.isEmpty) return;
    final color = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择颜色标记'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _colorOption(ctx, null, '无', Colors.grey),
            ...colorLabelMap.entries.map((e) => _colorOption(ctx, e.key, e.key, e.value)),
          ],
        ),
      ),
    );
    if (!mounted) return;
    final items = ref.read(vaultItemsProvider).valueOrNull ?? [];
    for (final id in ids) {
      final item = items.firstWhere((e) => e.id == id, orElse: () => VaultItem(id: '', type: VaultItemType.password, title: '', username: ''));
      if (item.id.isNotEmpty) {
        await ref.read(vaultItemsProvider.notifier).updateItem(item.copyWith(colorLabel: color ?? ''));
      }
    }
    ref.read(selectedItemIdsProvider.notifier).state = {};
    ref.read(isMultiSelectProvider.notifier).state = false;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已为 ${ids.length} 项设置颜色')));
    }
  }

  Widget _colorOption(BuildContext ctx, String? value, String label, Color color) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2),
            ),
            child: value == null ? Icon(Icons.block, color: Colors.grey[400], size: 20) : null,
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ExtensionHelper.isExtension) {
      ref.listen<AsyncValue<List<VaultItem>>>(vaultItemsProvider, (previous, next) {
        if (next is AsyncData<List<VaultItem>>) {
          debugPrint('📥 Vault items updated in build listener');
          if (_pendingCheckCurrentTab) {
            debugPrint('🎯 Triggering pending _checkCurrentTabMatch');
            _pendingCheckCurrentTab = false;
            _checkCurrentTabMatch();
          }
          if (_pendingHandleActiveContext) {
            debugPrint('🎯 Triggering pending _handleActiveContext');
            _pendingHandleActiveContext = false;
            _handleActiveContext();
          }
        }
      });
    }

    // Watch sync status to trigger UI refresh when background sync completes
    ref.watch(syncStatusProvider);

    final selectedIndex = ref.watch(selectedTabProvider);
    final isSearching = ref.watch(isSearchingProvider);
    final isMultiSelect = ref.watch(isMultiSelectProvider);
    final selectedIds = ref.watch(selectedItemIdsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: isMultiSelect
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  ref.read(isMultiSelectProvider.notifier).state = false;
                  ref.read(selectedItemIdsProvider.notifier).state = {};
                },
              )
            : null,
        title: isMultiSelect
            ? Text('已选 ${selectedIds.length} 项')
            : isSearching
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '全局搜索：标题、用户名、域名...',
                    border: InputBorder.none,
                  ),
                  onChanged: (value) {
                    ref.read(searchQueryProvider.notifier).state = value;
                  },
                )
              : Text(
                  selectedIndex == 0 ? '验证码' : (selectedIndex == 1 ? '帐号管理' : (selectedIndex == 2 ? '加密资产' : (selectedIndex == 3 ? '安全备注' : '设置'))),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
        centerTitle: !isSearching && !isMultiSelect,
        actions: [
          if (isMultiSelect) ...[
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: '全选',
              onPressed: () {
                final type = VaultItemType.values[selectedIndex];
                final items = ref.read(filteredVaultItemsProvider(type));
                ref.read(selectedItemIdsProvider.notifier).state =
                    items.map((e) => e.id).toSet();
              },
            ),
          ] else if (isSearching)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                ref.read(isSearchingProvider.notifier).state = false;
                ref.read(searchQueryProvider.notifier).state = '';
                _searchController.clear();
              },
            )
          else ...[
            if (selectedIndex == 0)
              IconButton(
                icon: const Icon(Icons.library_add_outlined),
                tooltip: '批量导入',
                onPressed: () => _showBulkImportDialog(context, ref),
              ),
            if (selectedIndex < 4)
              IconButton(
                icon: Icon(
                  ref.watch(showFavoritesOnlyProvider) ? Icons.star : Icons.star_border,
                  color: ref.watch(showFavoritesOnlyProvider) ? Colors.amber : null,
                ),
                tooltip: '只显示收藏',
                onPressed: () {
                  ref.read(showFavoritesOnlyProvider.notifier).state = !ref.read(showFavoritesOnlyProvider);
                },
              ),
            if (selectedIndex < 4) 
              IconButton(
                icon: const Icon(Icons.sort),
                tooltip: '排序',
                onPressed: () => _showSortMenu(context, ref),
              ),
            if (selectedIndex < 4)
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {
                  ref.read(isSearchingProvider.notifier).state = true;
                },
              ),
            if (selectedIndex < 4)
              IconButton(
                icon: const Icon(Icons.checklist),
                tooltip: '多选',
                onPressed: () {
                  ref.read(isMultiSelectProvider.notifier).state = true;
                  ref.read(selectedItemIdsProvider.notifier).state = {};
                },
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (selectedIndex < 4 && !isSearching && !isMultiSelect) const CategoryFilterBar(),
          if (selectedIndex < 4 && !isSearching && !isMultiSelect) const TagFilterBar(),
          if (selectedIndex < 4 && !isSearching && !isMultiSelect) const SharedVaultFilterIndicator(),
          Expanded(
            child: IndexedStack(
              index: selectedIndex,
              children: const [
                VaultListContent(type: VaultItemType.totp),
                VaultListContent(type: VaultItemType.password),
                VaultListContent(type: VaultItemType.crypto),
                VaultListContent(type: VaultItemType.secureNote),
                SettingsContent(),
              ],
            ),
          ),
          if (isMultiSelect && selectedIds.isNotEmpty)
            _buildBatchActionBar(context, ref),
        ],
      ),
      floatingActionButton: selectedIndex < 4 && !isSearching && !isMultiSelect
          ? FloatingActionButton.extended(
              onPressed: () {
                final sharedVaultId = ref.read(selectedSharedVaultIdProvider);
                if (selectedIndex == 0) {
                  _showAddItemDialog(context, ref, VaultItemType.totp);
                } else if (selectedIndex == 1) {
                  context.push('/add-account', extra: VaultItem(
                    id: '', 
                    type: VaultItemType.password, 
                    title: '', 
                    username: '',
                    sharedVaultId: sharedVaultId,
                  ));
                } else if (selectedIndex == 2) {
                  context.push('/add-account', extra: VaultItem(
                    id: '', 
                    type: VaultItemType.crypto, 
                    title: '', 
                    username: '',
                    sharedVaultId: sharedVaultId,
                  ));
                } else if (selectedIndex == 3) {
                  context.push('/add-account', extra: VaultItem(
                    id: '', 
                    type: VaultItemType.secureNote, 
                    title: '', 
                    username: '',
                    sharedVaultId: sharedVaultId,
                  ));
                }
              },
              label: Text(selectedIndex == 0 ? '添加代码' : (selectedIndex == 1 ? '添加帐号' : (selectedIndex == 2 ? '添加钱包' : '添加备注'))),
              icon: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          ref.read(selectedTabProvider.notifier).state = index;
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.security),
            selectedIcon: Icon(Icons.security),
            label: '2FA',
          ),
          NavigationDestination(
            icon: Icon(Icons.password),
            selectedIcon: Icon(Icons.password),
            label: '帐号',
          ),
          NavigationDestination(
            icon: Icon(Icons.currency_bitcoin),
            selectedIcon: Icon(Icons.currency_bitcoin),
            label: '加密资产',
          ),
          NavigationDestination(
            icon: Icon(Icons.note),
            selectedIcon: Icon(Icons.note),
            label: '安全备注',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

class SharedVaultFilterIndicator extends ConsumerWidget {
  const SharedVaultFilterIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedVaultId = ref.watch(selectedSharedVaultIdProvider);
    if (selectedVaultId == null) return const SizedBox.shrink();

    final sharedVaultsAsync = ref.watch(sharedVaultsProvider);
    return sharedVaultsAsync.when(
      data: (vaults) {
        final vault = vaults.where((v) => v.id == selectedVaultId).firstOrNull;
        if (vault == null) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
          child: Row(
            children: [
              const Icon(Icons.people_outline, size: 16),
              const SizedBox(width: 8),
              Text(
                '正在查看共享库: ${vault.name}',
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
  const VaultListContent({required this.type, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(filteredVaultItemsProvider(type));
    final vaultAsync = ref.watch(vaultItemsProvider);
    final isMultiSelect = ref.watch(isMultiSelectProvider);
    final selectedIds = ref.watch(selectedItemIdsProvider);
    
    return vaultAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(child: Text('加载失败: $err')),
      data: (_) {
        if (items.isEmpty) {
          final isFiltering = ref.watch(selectedCategoryProvider) != null || 
                             ref.watch(selectedTagProvider) != null ||
                             ref.watch(selectedSharedVaultIdProvider) != null ||
                             ref.watch(showFavoritesOnlyProvider) ||
                             ref.watch(searchQueryProvider).isNotEmpty;
          
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isFiltering ? Icons.search_off_rounded : Icons.inventory_2_outlined, 
                  size: 64, 
                  color: Colors.grey[400]
                ),
                const SizedBox(height: 16),
                Text(
                  isFiltering ? '没有找到匹配的项目' : '暂无数据', 
                  style: TextStyle(color: Colors.grey[600], fontSize: 16)
                ),
                if (isFiltering)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: TextButton(
                      onPressed: () {
                        ref.read(selectedCategoryProvider.notifier).state = null;
                        ref.read(selectedTagProvider.notifier).state = null;
                        ref.read(selectedSharedVaultIdProvider.notifier).state = null;
                        ref.read(showFavoritesOnlyProvider.notifier).state = false;
                        ref.read(searchQueryProvider.notifier).state = '';
                        ref.read(isSearchingProvider.notifier).state = false;
                      },
                      child: const Text('重置过滤器'),
                    ),
                  ),
              ],
            ),
          );
        }

        return ListView.builder(
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
                final current = Set<String>.from(ref.read(selectedItemIdsProvider));
                if (current.contains(item.id)) {
                  current.remove(item.id);
                } else {
                  current.add(item.id);
                }
                ref.read(selectedItemIdsProvider.notifier).state = current;
              },
              child: Stack(
                children: [
                  AbsorbPointer(child: _wrapWithColorIndicator(context, item, card)),
                  Positioned(
                    left: 4,
                    top: 12,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: isSelected ? Theme.of(context).colorScheme.primary : Colors.grey,
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

  Widget _wrapWithColorIndicator(BuildContext context, VaultItem item, Widget card) {
    final color = item.colorLabel != null && item.colorLabel!.isNotEmpty
        ? colorLabelMap[item.colorLabel]
        : null;
    if (color == null && !item.isPinned) return card;

    return Stack(
      children: [
        card,
        if (color != null)
          Positioned(
            left: 16, top: 8, bottom: 8,
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
            right: 20, top: 12,
            child: Icon(Icons.push_pin, size: 14, color: Theme.of(context).colorScheme.primary.withOpacity(0.6)),
          ),
      ],
    );
  }
}

class SettingsContent extends ConsumerWidget {
  const SettingsContent({super.key});

  void _showAutoLockDialog(BuildContext context, WidgetRef ref, int currentMinutes) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('自动锁定时间'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAutoLockOption(context, ref, '1 分钟', 1, currentMinutes),
            _buildAutoLockOption(context, ref, '5 分钟', 5, currentMinutes),
            _buildAutoLockOption(context, ref, '10 分钟', 10, currentMinutes),
            _buildAutoLockOption(context, ref, '30 分钟', 30, currentMinutes),
            _buildAutoLockOption(context, ref, '1 小时', 60, currentMinutes),
            _buildAutoLockOption(context, ref, '4 小时', 240, currentMinutes),
          ],
        ),
      ),
    );
  }

  void _showClearDataDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空所有数据'),
        content: const Text('确定要清空所有数据吗？此操作不可撤销，所有密码、共享库和同步配置将被永久删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () async {
              try {
                await ref.read(vaultItemsProvider.notifier).clearAllData();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('所有数据已成功清空'), backgroundColor: Colors.green),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('清空失败: $e'), backgroundColor: Colors.red),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('确认清空'),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoLockOption(BuildContext context, WidgetRef ref, String label, int minutes, int current) {
    return RadioListTile<int>(
      title: Text(label),
      value: minutes,
      groupValue: current,
      onChanged: (value) {
        if (value != null) {
          ref.read(masterPasswordProvider.notifier).setAutoLockMinutes(value);
          Navigator.pop(context);
        }
      },
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
        title: const Text('修改主密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '当前密码'),
            ),
            TextField(
              controller: newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '新密码'),
            ),
            TextField(
              controller: confirmPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: '确认新密码'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              if (oldPasswordController.text != masterState.password) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('当前密码错误'), backgroundColor: Colors.red),
                );
                return;
              }
              if (newPasswordController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('新密码不能为空'), backgroundColor: Colors.red),
                );
                return;
              }
              if (newPasswordController.text != confirmPasswordController.text) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('两次输入的新密码不一致'), backgroundColor: Colors.red),
                );
                return;
              }

              ref.read(masterPasswordProvider.notifier).setPassword(newPasswordController.text);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('主密码已修改')),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final masterState = ref.watch(masterPasswordProvider);
    final healthReport = ref.watch(passwordHealthProvider);
    final totalIssues = healthReport.weakCount + healthReport.reusedCount + healthReport.expiredCount;

    return ListView(
      children: [
        _buildSection(context, '安全', [
          ListTile(
            leading: const Icon(Icons.security),
            title: const Text('安全检查'),
            subtitle: Text(totalIssues > 0 ? '发现 $totalIssues 个风险' : '未发现风险'),
            trailing: totalIssues > 0 
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
            title: const Text('修改主密码'),
            onTap: () => _showChangeMasterPasswordDialog(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('生物识别解锁'),
            trailing: Switch(
              value: masterState.isBiometricEnabled,
              onChanged: (v) => ref.read(masterPasswordProvider.notifier).setBiometricEnabled(v),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('自动锁定'),
            subtitle: Text('${masterState.autoLockMinutes} 分钟'),
            onTap: () => _showAutoLockDialog(context, ref, masterState.autoLockMinutes),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('锁定密码库'),
            onTap: () {
              ref.read(masterPasswordProvider.notifier).setAuthenticated(false);
            },
          ),
        ]),
        _buildSection(context, '外观', [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('主题模式'),
            subtitle: Text(_themeModeName(ref.watch(themeModeProvider))),
            onTap: () => _showThemeModeDialog(context, ref),
          ),
        ]),
        _buildSection(context, '工具', [
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('密码生成器'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.go('/password-generator'),
          ),
        ]),
        _buildSection(context, '协作与共享', [
          ListTile(
            leading: const Icon(Icons.people_outline),
            title: const Text('共享库 (家庭/团队)'),
            subtitle: const Text('零知识共享文件夹'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/sharing'),
          ),
        ]),
        _buildSection(context, '数据管理', [
          ListTile(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('WebDAV 同步'),
            subtitle: Text(ref.watch(webDavConfigProvider).isValid ? '已配置' : '未配置'),
            onTap: () => context.push('/backup'),
          ),
          ListTile(
            leading: const Icon(Icons.sync_alt),
            title: const Text('局域网同步'),
            onTap: () => context.push('/local-sync'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('回收站'),
            onTap: () => context.push('/recycle-bin'),
          ),
          ListTile(
            leading: const Icon(Icons.import_export),
            title: const Text('导入与导出'),
            onTap: () => _showImportExport(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined, color: Colors.red),
            title: const Text('清空所有数据', style: TextStyle(color: Colors.red)),
            onTap: () => _showClearDataDialog(context, ref),
          ),
        ]),
        _buildSection(context, '关于', [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('版本'),
            trailing: Text('1.0.0'),
          ),
        ]),
      ],
    );
  }

  String _themeModeName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system: return '跟随系统';
      case ThemeMode.light: return '浅色';
      case ThemeMode.dark: return '深色';
    }
  }

  void _showThemeModeDialog(BuildContext context, WidgetRef ref) {
    final current = ref.read(themeModeProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('主题模式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<ThemeMode>(
              title: const Text('跟随系统'),
              secondary: const Icon(Icons.brightness_auto),
              value: ThemeMode.system,
              groupValue: current,
              onChanged: (v) {
                ref.read(themeModeProvider.notifier).setThemeMode(v!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<ThemeMode>(
              title: const Text('浅色模式'),
              secondary: const Icon(Icons.light_mode),
              value: ThemeMode.light,
              groupValue: current,
              onChanged: (v) {
                ref.read(themeModeProvider.notifier).setThemeMode(v!);
                Navigator.pop(context);
              },
            ),
            RadioListTile<ThemeMode>(
              title: const Text('深色模式'),
              secondary: const Icon(Icons.dark_mode),
              value: ThemeMode.dark,
              groupValue: current,
              onChanged: (v) {
                ref.read(themeModeProvider.notifier).setThemeMode(v!);
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...children,
        const Divider(),
      ],
    );
  }
}

class CategoryFilterBar extends ConsumerWidget {
  const CategoryFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final selectedCategory = ref.watch(selectedCategoryProvider);

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
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
            '全部',
            selectedCategory == null,
            () => ref.read(selectedCategoryProvider.notifier).state = null,
            icon: Icons.grid_view_rounded,
          ),
          ...categories.map((category) => _buildCategoryChip(
                context,
                ref,
                category,
                selectedCategory == category,
                () => ref.read(selectedCategoryProvider.notifier).state = category,
                icon: _getCategoryIcon(category),
              )),
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
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => onSelected(),
        avatar: icon != null ? Icon(icon, size: 16, color: isSelected ? colorScheme.onPrimary : colorScheme.primary) : null,
        showCheckmark: false,
        backgroundColor: colorScheme.surfaceVariant.withOpacity(0.3),
        selectedColor: colorScheme.primary,
        labelStyle: TextStyle(
          color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
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
    final tags = ref.watch(allTagsProvider);
    final selectedTag = ref.watch(selectedTagProvider);

    if (tags.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 40,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('所有标签', style: TextStyle(fontSize: 12)),
              selected: selectedTag == null,
              onSelected: (selected) {
                if (selected) {
                  ref.read(selectedTagProvider.notifier).state = null;
                }
              },
            ),
          ),
          ...tags.map((tag) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(tag, style: const TextStyle(fontSize: 12)),
                  selected: selectedTag == tag,
                  onSelected: (selected) {
                    ref.read(selectedTagProvider.notifier).state = selected ? tag : null;
                  },
                ),
              )),
        ],
      ),
    );
  }
}
