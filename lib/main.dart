import 'dart:ui';
import 'package:flutter/material.dart';
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

// --- Providers ---
// 移除了硬编码的 vaultItemsProvider，改用 vault_provider.dart 中的实现

final selectedTabProvider = StateProvider<int>((ref) => 0);
final searchQueryProvider = StateProvider<String>((ref) => '');
final isSearchingProvider = StateProvider<bool>((ref) => false);

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
      path: '/',
      builder: (context, state) => const AuthGuard(child: MainNavigationScreen()),
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

class SecurePassApp extends StatelessWidget {
  const SecurePassApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SecurePass',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
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

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
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
              ),
              obscureText: type == VaultItemType.password,
            ),
            if (type == VaultItemType.password)
              TextField(
                controller: urlController,
                decoration: const InputDecoration(labelText: '网站链接 (可选)'),
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
              id: Uuid().v4(),
              type: type,
              title: titleController.text,
              username: usernameController.text,
              secret: type == VaultItemType.totp ? secretOrPasswordController.text : null,
              password: type == VaultItemType.password ? secretOrPasswordController.text : null,
              url: urlController.text.isEmpty ? null : urlController.text,
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
    ),
  );
}

class MainNavigationScreen extends ConsumerStatefulWidget {
  const MainNavigationScreen({super.key});

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
    if (ExtensionHelper.isExtension) {
      _pendingCheckCurrentTab = true;
      _pendingHandleActiveContext = true;
      ref.listen<AsyncValue<List<VaultItem>>>(vaultItemsProvider, (previous, next) {
        if (next is AsyncData<List<VaultItem>>) {
          if (_pendingCheckCurrentTab) {
            _pendingCheckCurrentTab = false;
            _checkCurrentTabMatch();
          }
          if (_pendingHandleActiveContext) {
            _pendingHandleActiveContext = false;
            _handleActiveContext();
          }
        }
      });
      _checkPendingSaves();
      _tryRunPendingExtensionChecks();
    }
  }

  void _tryRunPendingExtensionChecks() {
    final vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is AsyncData<List<VaultItem>>) {
      // Execute checks with a small delay to ensure UI is ready
      Future.delayed(const Duration(milliseconds: 200), () {
        if (!mounted) return;
        if (_pendingHandleActiveContext) {
          _pendingHandleActiveContext = false;
          _handleActiveContext();
        } else if (_pendingCheckCurrentTab) {
          _pendingCheckCurrentTab = false;
          _checkCurrentTabMatch();
        }
      });
    }
  }

  Future<void> _checkCurrentTabMatch() async {
    debugPrint('🔍 Checking current tab for matches...');
    
    // Wait a bit for UI to be ready
    await Future.delayed(const Duration(milliseconds: 300));
    
    if (!mounted) return;
    
    final url = await ExtensionHelper.getCurrentTabUrl();
    if (url == null || url.isEmpty) {
      debugPrint('⚠️ No URL found for current tab');
      return;
    }

    final host = _extractHost(url);
    if (host.isEmpty) {
      debugPrint('⚠️ Could not extract host from URL: $url');
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
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) return;

    final items = vaultItemsAsync.valueOrNull ?? [];
    final matchingItems = items.where((item) {
      if (item.type != VaultItemType.password) return false;
      if (item.url == null || item.url!.isEmpty) return false;
      return _hostMatches(item.url, url);
    }).toList();

    if (matchingItems.isNotEmpty) {
      debugPrint('🎯 Found ${matchingItems.length} match(es) for current tab: $host');
      if (mounted) {
        // Switch to Vault tab (index 1)
        ref.read(selectedTabProvider.notifier).state = 1;
        
        // Wait a bit for tab switch to complete
        await Future.delayed(const Duration(milliseconds: 100));
        
        if (!mounted) return;
        
        // Always enable search and search for the host
        debugPrint('🔍 Setting search query: $host');
        ref.read(isSearchingProvider.notifier).state = true;
        ref.read(searchQueryProvider.notifier).state = host;
        _searchController.text = host;
        
        // Clear category filter to show all matching items
        ref.read(selectedCategoryProvider.notifier).state = null;
        
        debugPrint('✅ Successfully navigated to account page with search: $host');
      }
    } else {
      debugPrint('ℹ️ No matching accounts found for: $host');
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
        context.push('/add-account', extra: exactMatch);
      } else {
        debugPrint('➕ No exact match for mismatch, navigating to add...');
        ref.read(selectedTabProvider.notifier).state = 1;
        context.push('/add-account', extra: VaultItem(
          id: '',
          type: VaultItemType.password,
          title: _extractHost(url),
          username: username ?? '',
          url: url,
        ));
      }
      
      await ExtensionHelper.clearActiveContext();
      return;
    }

    if (origin == null) return;

    // Wait for vault items to be loaded if needed
    var vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) {
      debugPrint('⏳ Waiting for vault items to load...');
      // Wait for data with timeout
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

    if (matches.isNotEmpty) {
      debugPrint('✅ Found ${matches.length} matching items, navigating to account page with search...');
      // Switch to vault tab first
      ref.read(selectedTabProvider.notifier).state = 1;
      
      // Wait a bit for tab switch to complete
      await Future.delayed(const Duration(milliseconds: 100));
      
      if (!mounted) return;
      
      // Extract host from origin and search for it
      final host = _extractHost(origin);
      if (host.isNotEmpty) {
        debugPrint('🔍 Setting search query: $host');
        ref.read(isSearchingProvider.notifier).state = true;
        ref.read(searchQueryProvider.notifier).state = host;
        _searchController.text = host;
        
        // Clear category filter to show all matching items
        ref.read(selectedCategoryProvider.notifier).state = null;
        
        debugPrint('✅ Successfully navigated to account page with search: $host');
      }
    } else {
      debugPrint('➕ No matching items, navigating to add...');
      // Navigate to add-account page with pre-filled data
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
                decoration: const InputDecoration(labelText: '网站'),
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
                    existingMatch!,
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
    );
  }

  String _extractHost(String? url) {
    if (url == null || url.trim().isEmpty) return '';
    final trimmed = url.trim();
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
    final itemHost = _extractHost(itemUrl);
    if (itemHost.isEmpty) return false;

    final originHost = _extractHost(originOrUrl);
    if (originHost.isEmpty) return itemUrl.toLowerCase().contains(originOrUrl.toLowerCase());

    return itemHost == originHost ||
        itemHost.endsWith('.$originHost') ||
        originHost.endsWith('.$itemHost');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = ref.watch(selectedTabProvider);
    final isSearching = ref.watch(isSearchingProvider);

    return Scaffold(
      appBar: AppBar(
        title: isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索标题、用户名或备注...',
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
        centerTitle: !isSearching,
        actions: [
          if (isSearching)
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
                icon: const Icon(Icons.search),
                onPressed: () {
                  ref.read(isSearchingProvider.notifier).state = true;
                },
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (selectedIndex < 4 && !isSearching) const CategoryFilterBar(),
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
        ],
      ),
      floatingActionButton: selectedIndex < 4 && !isSearching
          ? FloatingActionButton.extended(
              onPressed: () {
                if (selectedIndex == 0) {
                  _showAddItemDialog(context, ref, VaultItemType.totp);
                } else if (selectedIndex == 1) {
                  context.push('/add-account', extra: VaultItem(
                    id: '', 
                    type: VaultItemType.password, 
                    title: '', 
                    username: ''
                  ));
                } else if (selectedIndex == 2) {
                  context.push('/add-account', extra: VaultItem(
                    id: '', 
                    type: VaultItemType.crypto, 
                    title: '', 
                    username: ''
                  ));
                } else if (selectedIndex == 3) {
                  context.push('/add-account', extra: VaultItem(
                    id: '', 
                    type: VaultItemType.secureNote, 
                    title: '', 
                    username: ''
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

class VaultListContent extends ConsumerWidget {
  final VaultItemType type;
  const VaultListContent({required this.type, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(filteredVaultItemsProvider(type));
    final vaultAsync = ref.watch(vaultItemsProvider);
    
    return vaultAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, stack) => Center(child: Text('加载失败: $err')),
      data: (_) {
        if (items.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.inventory_2_outlined, size: 64, color: Colors.grey[400]),
                const SizedBox(height: 16),
                Text('暂无数据', style: TextStyle(color: Colors.grey[600])),
              ],
            ),
          );
        }

        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            switch (item.type) {
              case VaultItemType.totp:
                return TotpItemCard(item: item);
              case VaultItemType.password:
                return PasswordItemCard(item: item);
              case VaultItemType.crypto:
                return CryptoItemCard(item: item);
              case VaultItemType.secureNote:
                return SecureNoteItemCard(item: item);
            }
          },
        );
      },
    );
  }
}

class SettingsContent extends ConsumerWidget {
  const SettingsContent({super.key});

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

  void _showSecurityReport(BuildContext context, PasswordHealthReport report) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '安全报告',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem(context, '弱密码', report.weakCount, Colors.red),
                  _buildStatItem(context, '重复使用', report.reusedCount, Colors.orange),
                  _buildStatItem(context, '已过期', report.expiredCount, Colors.blue),
                ],
              ),
              const SizedBox(height: 30),
              const Text(
                '详细建议',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [
                    if (report.weakCount > 0)
                      _buildAdviceItem(
                        context,
                        Icons.warning_amber_rounded,
                        Colors.red,
                        '修改弱密码',
                        '有 ${report.weakCount} 个账号使用了弱密码。建议使用长度至少 12 位，且包含大小写字母、数字和符号的随机密码。',
                      ),
                    if (report.reusedCount > 0)
                      _buildAdviceItem(
                        context,
                        Icons.repeat,
                        Colors.orange,
                        '避免重复使用密码',
                        '有 ${report.reusedCount} 个账号重复使用了相同的密码。如果其中一个账号被破解，其他账号也会面临风险。',
                      ),
                    if (report.expiredCount > 0)
                      _buildAdviceItem(
                        context,
                        Icons.history,
                        Colors.blue,
                        '定期更换密码',
                        '有 ${report.expiredCount} 个账号的密码已超过建议的使用期限。建议定期更换重要账号的密码。',
                      ),
                    if (report.weakCount == 0 && report.reusedCount == 0 && report.expiredCount == 0)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Column(
                            children: [
                              Icon(Icons.check_circle, color: Colors.green, size: 64),
                              SizedBox(height: 16),
                              Text('太棒了！您的密码库非常安全。'),
                            ],
                          ),
                        ),
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

  Widget _buildStatItem(BuildContext context, String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color),
        ),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }

  Widget _buildAdviceItem(BuildContext context, IconData icon, Color color, String title, String advice) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(advice, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
              ],
            ),
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
            onTap: () => _showSecurityReport(context, healthReport),
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
            leading: const Icon(Icons.logout),
            title: const Text('锁定密码库'),
            onTap: () {
              ref.read(masterPasswordProvider.notifier).setAuthenticated(false);
            },
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
        _buildSection(context, '数据管理', [
          ListTile(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: const Text('WebDAV 同步'),
            subtitle: Text(ref.watch(webDavConfigProvider).isValid ? '已配置' : '未配置'),
            onTap: () => context.push('/backup'),
          ),
          ListTile(
            leading: const Icon(Icons.import_export),
            title: const Text('导入与导出'),
            onTap: () => _showImportExport(context, ref),
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
      height: 50,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('全部'),
              selected: selectedCategory == null,
              onSelected: (selected) {
                if (selected) {
                  ref.read(selectedCategoryProvider.notifier).state = null;
                }
              },
            ),
          ),
          ...categories.map((category) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(category),
                  selected: selectedCategory == category,
                  onSelected: (selected) {
                    if (selected) {
                      ref.read(selectedCategoryProvider.notifier).state = category;
                    } else if (selectedCategory == category) {
                      ref.read(selectedCategoryProvider.notifier).state = null;
                    }
                  },
                ),
              )),
        ],
      ),
    );
  }
}
