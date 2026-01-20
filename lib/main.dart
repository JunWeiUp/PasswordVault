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
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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
                  int count = 0;
                  for (final item in importedItems) {
                    try {
                      // 为导入的项目生成新的 ID，避免冲突
                      final newItem = VaultItem(
                        id: const Uuid().v4(),
                        type: item.type,
                        title: item.title,
                        username: item.username,
                        secret: item.secret,
                        password: item.password,
                        mnemonic: item.mnemonic,
                        address: item.address,
                        period: item.period,
                        isFavorite: item.isFavorite,
                        url: item.url,
                        note: item.note,
                      );
                      await ref.read(vaultItemsProvider.notifier).addItem(newItem);
                      count++;
                    } catch (e) {
                      debugPrint('Import item failed: $e');
                    }
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('成功导入 $count 个项目')),
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
                  int count = 0;
                  for (final item in importedItems) {
                    try {
                      await ref.read(vaultItemsProvider.notifier).addItem(item);
                      count++;
                    } catch (e) {
                      debugPrint('Import item failed: $e');
                    }
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('成功从 LastPass 导入 $count 个项目')),
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

  @override
  void initState() {
    super.initState();
    if (ExtensionHelper.isExtension) {
      _checkPendingSaves();
      _handleActiveContext();
      _checkCurrentTabMatch();
    }
  }

  Future<void> _checkCurrentTabMatch() async {
    debugPrint('🔍 Checking current tab for matches...');
    final url = await ExtensionHelper.getCurrentTabUrl();
    if (url == null || url.isEmpty) return;

    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return;

    // Wait for items to be loaded
    final vaultItemsAsync = ref.read(vaultItemsProvider);
    if (vaultItemsAsync is AsyncLoading) {
      await Future.delayed(const Duration(milliseconds: 500));
      return _checkCurrentTabMatch();
    }

    final items = vaultItemsAsync.valueOrNull ?? [];
    final matchingItem = items.where((item) {
      if (item.url == null || item.url!.isEmpty) return false;
      try {
        final itemUri = Uri.parse(item.url!);
        return itemUri.host.toLowerCase() == host;
      } catch (e) {
        return item.url!.toLowerCase().contains(host);
      }
    }).firstOrNull;

    if (matchingItem != null) {
      debugPrint('🎯 Found match for current tab: ${matchingItem.title}');
      if (mounted) {
        // Switch to Vault tab (index 1)
        ref.read(selectedTabProvider.notifier).state = 1;
        
        if (matchingItem.category != null) {
          debugPrint('📂 Setting category filter: ${matchingItem.category}');
          ref.read(selectedCategoryProvider.notifier).state = matchingItem.category;
        } else {
          // If no category, just search for the title/host
          debugPrint('🔍 No category, setting search query: $host');
          ref.read(isSearchingProvider.notifier).state = true;
          ref.read(searchQueryProvider.notifier).state = host;
          _searchController.text = host;
        }
      }
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
    if (origin == null) return;

    debugPrint('🎯 Handling active context for origin: $origin');

    // Wait for vault items to be loaded
    final vaultItemsAsync = ref.read(vaultItemsProvider);
    
    // If it's loading or has an error, we might need to wait or skip
    if (vaultItemsAsync is AsyncLoading) {
      debugPrint('⏳ Vault items still loading, waiting...');
      // We can't easily wait here without complex logic, but we can try again after a short delay
      Future.delayed(const Duration(milliseconds: 500), _handleActiveContext);
      return;
    }

    final vaultItems = vaultItemsAsync.valueOrNull ?? [];
    
    // Find matching items for this origin
    final matches = vaultItems.where((item) => 
      item.type == VaultItemType.password && 
      (item.url?.contains(origin) ?? false)
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

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存新账号'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              final newItem = VaultItem(
                id: const Uuid().v4(),
                type: VaultItemType.password,
                title: titleController.text,
                username: usernameController.text,
                password: passwordController.text,
                url: urlController.text,
              );

              try {
                await ref.read(vaultItemsProvider.notifier).addItem(newItem);
                await ExtensionHelper.clearPendingSaves();
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存到保险箱')));
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red));
                }
              }
            },
            child: const Text('保存'),
          ),
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
                selectedIndex == 0 ? '验证码' : (selectedIndex == 1 ? '帐号管理' : (selectedIndex == 2 ? '加密资产' : '设置')),
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
            if (selectedIndex < 3)
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
          if (selectedIndex < 3 && !isSearching) const CategoryFilterBar(),
          Expanded(
            child: IndexedStack(
              index: selectedIndex,
              children: const [
                VaultListContent(type: VaultItemType.totp),
                VaultListContent(type: VaultItemType.password),
                VaultListContent(type: VaultItemType.crypto),
                SettingsContent(),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: selectedIndex < 3 && !isSearching
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
                }
              },
              label: Text(selectedIndex == 0 ? '添加代码' : (selectedIndex == 1 ? '添加帐号' : '添加钱包')),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final masterState = ref.watch(masterPasswordProvider);

    return ListView(
      children: [
        _buildSection(context, '安全', [
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
