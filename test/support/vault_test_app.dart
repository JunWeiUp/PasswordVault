import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:go_router/go_router.dart';
import 'package:password/core/l10n/l10n.dart';
import 'package:password/core/theme/app_theme.dart';
import 'package:password/features/sync/presentation/providers/sync_provider.dart';
import 'package:password/features/totp/presentation/providers/totp_provider.dart';
import 'package:password/features/vault/domain/models/vault_item.dart';
import 'package:password/features/vault/presentation/pages/password_generator_page.dart';
import 'package:password/features/vault/presentation/pages/vault_workspace_page.dart';
import 'package:password/features/vault/presentation/providers/vault_provider.dart';

/// Fictional, memory-only data. This fixture never opens a vault or a network service.
void initializeVaultFixtureStorage() {
  SharedPreferences.setMockInitialValues({});
  FlutterSecureStorage.setMockInitialValues({});
}

List<VaultItem> sampleVaultItems() => [
  for (final entry in [
    ('Northstar', 'alex@example.com', '工作', ['Work'], true),
    ('Paper & ink', 'alex.writer@example.com', '工作', ['Writing'], false),
    ('Sunday studio', 'hello@example.com', '社交媒体', ['Personal'], false),
    ('Field notes', 'alex@example.com', '工作', ['Work'], false),
    ('Atlas travel', 'explore@example.com', '娱乐', ['Personal'], false),
  ])
    VaultItem(
      id: entry.$1,
      type: VaultItemType.password,
      title: entry.$1,
      username: entry.$2,
      password: 'Example-${entry.$1}!984',
      category: entry.$3,
      tags: entry.$4,
      isFavorite: entry.$5,
      updatedAt: DateTime(2026, 9, 8),
    ),
  VaultItem(
    id: 'sample-code',
    type: VaultItemType.totp,
    title: 'Northstar',
    username: 'alex@example.com',
    secret: 'JBSWY3DPEHPK3PXP',
  ),
  VaultItem(
    id: 'sample-note',
    type: VaultItemType.secureNote,
    title: 'A few things to remember',
    username: '',
    note: 'Fictional notes for the product preview.',
  ),
];

class MemoryVaultNotifier extends StateNotifier<AsyncValue<List<VaultItem>>>
    implements VaultNotifier {
  MemoryVaultNotifier(List<VaultItem> items) : super(AsyncData(items));
  @override
  Future<void> refresh() async {}
  @override
  Future<void> updateItem(VaultItem item) async {
    state = AsyncData([
      for (final old in state.requireValue) old.id == item.id ? item : old,
    ]);
  }

  @override
  Future<void> softDeleteItem(String id) async {
    state = AsyncData(
      state.requireValue.where((item) => item.id != id).toList(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer createVaultFixture({List<VaultItem>? items}) =>
    ProviderContainer(
      overrides: [
        vaultItemsProvider.overrideWith(
          (_) => MemoryVaultNotifier(items ?? sampleVaultItems()),
        ),
        syncStatusProvider.overrideWith((_) => const Stream<bool>.empty()),
        tickerProvider.overrideWith((_) => const Stream<int>.empty()),
        sharedVaultsProvider.overrideWith((_) async => []),
      ],
    );

class VaultTestApp extends ConsumerWidget {
  const VaultTestApp({
    super.key,
    this.home,
    this.dark = false,
    this.textScale = 1,
  });
  final Widget? home;
  final bool dark;
  final double textScale;
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: ref.watch(localeProvider),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: dark ? AppTheme.dark : AppTheme.light,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home ?? const MainNavigationScreen(),
  );
}

GoRouter fixtureRouter() => GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, _) => const MainNavigationScreen()),
    GoRoute(
      path: '/password-generator',
      builder: (_, _) => const PasswordGeneratorPage(),
    ),
  ],
);
