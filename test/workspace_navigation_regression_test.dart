import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:password/core/providers/app_providers.dart';
import 'package:password/features/vault/domain/models/vault_item.dart';
import 'package:password/features/vault/presentation/pages/add_account_page.dart';
import 'package:password/features/vault/presentation/pages/lock_page.dart';
import 'package:password/features/vault/presentation/pages/password_generator_page.dart';
import 'package:password/features/vault/presentation/pages/vault_workspace_page.dart';
import 'package:password/features/vault/presentation/providers/master_key_provider.dart';
import 'package:password/features/vault/presentation/providers/vault_provider.dart';
import 'package:password/main.dart' show SecurePassApp;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/vault_test_app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<ProviderContainer> launchWorkspace(
    WidgetTester tester, {
    Size size = const Size(1100, 820),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final container = createVaultFixture();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const VaultTestApp(),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('phone search keeps results visible above the keyboard', (
    tester,
  ) async {
    final container = await launchWorkspace(tester, size: const Size(320, 640));
    final search = find.byKey(const ValueKey('vault-search'));
    await tester.tap(search);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.enterText(search, 'Paper');
    await tester.pumpAndSettle();

    expect(container.read(searchQueryProvider), 'Paper');
    expect(find.byType(CategoryFilterBar), findsNothing);
    expect(find.byType(TagFilterBar), findsNothing);
    final result = find.text('Paper & ink');
    expect(result.hitTestable(), findsOneWidget);
    expect(tester.getRect(result).bottom, lessThanOrEqualTo(340));
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching collection clears a category absent from that type', (
    tester,
  ) async {
    final container = await launchWorkspace(tester);
    final workCategory = find.descendant(
      of: find.byType(CategoryFilterBar),
      matching: find.text('Work'),
    );
    await tester.tap(workCategory);
    await tester.pumpAndSettle();
    expect(container.read(selectedCategoryProvider), '工作');
    expect(find.text('Paper & ink'), findsOneWidget);
    expect(find.text('Sunday studio'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-3')));
    await tester.pumpAndSettle();
    expect(container.read(selectedTabProvider), 3);
    expect(container.read(selectedCategoryProvider), isNull);
    expect(find.text('A few things to remember'), findsOneWidget);
    expect(find.text('No matching items'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multi-select hides filters that could conceal selected items', (
    tester,
  ) async {
    final container = await launchWorkspace(tester);
    expect(find.byType(CategoryFilterBar), findsOneWidget);
    expect(find.byType(TagFilterBar), findsOneWidget);
    await tester.tap(find.byTooltip('Tools').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select multiple'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select all'));
    await tester.pumpAndSettle();

    expect(container.read(isMultiSelectProvider), isTrue);
    expect(container.read(selectedItemIdsProvider), hasLength(5));
    expect(find.byType(CategoryFilterBar), findsNothing);
    expect(find.byType(TagFilterBar), findsNothing);
    expect(find.byType(SharedVaultFilterIndicator), findsNothing);

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(isMultiSelectProvider), isFalse);
    expect(container.read(selectedItemIdsProvider), isEmpty);
    expect(find.byType(CategoryFilterBar), findsOneWidget);
    expect(find.byType(TagFilterBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'locked direct routes never mount protected editor or generator',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'saved_master_password': 'Fixture-Route-Only!984',
      });
      final container = createVaultFixture();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SecurePassApp(),
        ),
      );
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(LockPage).first));
      addTearDown(() async {
        router.go('/');
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      });
      expect(container.read(masterPasswordProvider).isAuthenticated, isFalse);
      final item = VaultItem(
        id: 'locked-route-fixture',
        type: VaultItemType.password,
        title: 'Protected fixture account',
        username: 'fixture@example.invalid',
        password: 'Fixture-Route-Only!984',
      );

      router.go('/add-account', extra: item);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/add-account');
      expect(find.byType(LockPage), findsOneWidget);
      expect(find.byType(AddAccountPage, skipOffstage: false), findsNothing);
      expect(find.text(item.title), findsNothing);
      expect(container.read(masterPasswordProvider).isAuthenticated, isFalse);
      expect(tester.takeException(), isNull);

      router.go('/password-generator');
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        '/password-generator',
      );
      expect(find.byType(LockPage), findsOneWidget);
      expect(
        find.byType(PasswordGeneratorPage, skipOffstage: false),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('generated-password')), findsNothing);
      expect(container.read(masterPasswordProvider).isAuthenticated, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
