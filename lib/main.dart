import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';
import 'features/totp/presentation/widgets/totp_item_card.dart';
import 'features/vault/presentation/providers/vault_provider.dart';
import 'features/vault/domain/models/vault_item.dart';
import 'package:uuid/uuid.dart';
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
            leading: const Icon(Icons.file_upload),
            title: const Text('导入数据 (JSON)'),
            onTap: () async {
              Navigator.pop(context);
              final importedItems = await ImportExportHelper.importFromJson();
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
