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

import 'features/vault/presentation/pages/recycle_bin_page.dart';
import 'features/vault/presentation/pages/security_audit_page.dart';

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
      path: '/recycle-bin',
      builder: (context, state) => const AuthGuard(child: RecycleBinPage()),
    ),
    GoRoute(
      path: '/security-audit',
      builder: (context, state) => const AuthGuard(child: SecurityAuditPage()),
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
      _checkPendingSaves();
      _tryRunPendingExtensionChecks();
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
    final contextData = await ExtensionHelper.getActiveContext();
    if (contextData == null) {
      debugPrint('ℹ️ No active context found.');
      return;
    }

    final origin = contextData['origin'] as String?;
    final type = contextData['type'] as String?;
    
    if (origin == null && type != 'mismatch_detected') return;

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

    final vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is! AsyncData<List<VaultItem>>) return;

    final vaultItems = vaultItemsAsync.valueOrNull ?? [];
    
    // Find matching items for this origin
    final matches = vaultItems.where((item) => 
      item.type == VaultItemType.password && 
      _hostMatches(item.url, origin)
    ).toList();

    if (!mounted) return;

    if (matches.isNotEmpty) {
      debugPrint('✅ Found ${matches.length} matching items, navigating to edit...');
      // Switch to vault tab first
      ref.read(selectedTabProvider.notifier).state = 1;
      
      final username = contextData['username'] as String?;
      final exactMatch = matches.where((m) => m.username == username).firstOrNull ?? matches.first;
      
      // Navigate to add-account page which also serves as edit page when extra is provided
      context.push('/add-account', extra: exactMatch);
    } else {
      debugPrint('➕ No matching items, navigating to add...');
      // Navigate to add-account page with pre-filled data
      context.push('/add-account', extra: VaultItem(
        id: '',
        type: VaultItemType.password,
        title: origin.split('//').last,
        username: contextData['username'] ?? '',
        url: contextData['url'],
      ));
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
          final isFiltering = ref.watch(selectedCategoryProvider) != null || 
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
            leading: const Icon(Icons.delete_outline),
            title: const Text('回收站'),
            onTap: () => context.push('/recycle-bin'),
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
