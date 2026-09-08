import 'package:password/core/l10n/l10n.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/theme/app_theme.dart';
import 'features/vault/domain/models/vault_item.dart';
import 'features/vault/presentation/pages/add_account_page.dart';
import 'features/vault/presentation/pages/password_generator_page.dart';
import 'features/vault/presentation/pages/lock_page.dart';
import 'features/vault/presentation/providers/master_key_provider.dart';
import 'features/backup/presentation/pages/webdav_config_page.dart';
import 'features/backup/presentation/pages/backup_page.dart';
import 'features/vault/presentation/pages/recycle_bin_page.dart';
import 'features/vault/presentation/pages/security_audit_page.dart';
import 'features/sync/presentation/pages/local_sync_page.dart';
import 'features/vault/presentation/pages/sharing/shared_vault_list_page.dart';
import 'features/vault/presentation/pages/sharing/create_shared_vault_page.dart';
import 'features/vault/presentation/pages/sharing/share_public_key_page.dart';
import 'features/vault/presentation/pages/sharing/add_member_page.dart';
import 'features/vault/presentation/pages/sharing/shared_vault_details_page.dart';
import 'features/vault/presentation/pages/sharing/lan_discovery_page.dart';
import 'core/providers/app_providers.dart';
import 'features/vault/presentation/pages/vault_workspace_page.dart';

export 'core/providers/app_providers.dart'
    show searchQueryProvider, selectedTabProvider, isSearchingProvider;
export 'features/vault/presentation/pages/vault_workspace_page.dart'
    show MainNavigationScreen, VaultListContent, SettingsContent;

// --- Router ---
final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/lock', builder: (context, state) => const LockPage()),
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
      builder: (context, state) =>
          const AuthGuard(child: SharedVaultListPage()),
    ),
    GoRoute(
      path: '/sharing/create',
      builder: (context, state) =>
          const AuthGuard(child: CreateSharedVaultPage()),
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
        return AuthGuard(
          child: SharedVaultDetailsPage(vaultId: vaultId, vault: vault),
        );
      },
    ),
    GoRoute(
      path: '/',
      builder: (context, state) {
        final extra = state.extra;
        final filterVaultId = extra is Map<String, dynamic>
            ? extra['filterVaultId'] as String?
            : null;
        return AuthGuard(
          child: MainNavigationScreen(filterVaultId: filterVaultId),
        );
      },
      routes: [
        GoRoute(
          path: 'add-account',
          builder: (context, state) {
            final item = state.extra as VaultItem?;
            return AuthGuard(child: AddAccountPage(item: item));
          },
        ),
        GoRoute(
          path: 'password-generator',
          builder: (context, state) =>
              const AuthGuard(child: PasswordGeneratorPage()),
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
    AppLocalizations.of(context);
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
    final locale = ref.watch(localeProvider);
    return MaterialApp.router(
      title: 'PasswordVault',
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
