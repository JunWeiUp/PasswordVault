import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/core/providers/app_providers.dart';
import 'package:password/features/vault/presentation/providers/vault_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/vault_test_app.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    Size size = const Size(1100, 820),
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = createVaultFixture();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: VaultTestApp(textScale: scale),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('search reset clears both visible input and active filters', (
    tester,
  ) async {
    final container = await launch(tester);
    await tester.enterText(
      find.byKey(const ValueKey('vault-search')),
      'no-match',
    );
    await tester.pumpAndSettle();
    expect(find.text('No matching items'), findsOneWidget);
    await tester.tap(find.text('Reset filters'));
    await tester.pumpAndSettle();
    expect(container.read(searchQueryProvider), isEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('vault-search')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text('Paper & ink'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'select all uses account IDs and switching collection clears selection',
    (tester) async {
      final container = await launch(tester);
      await tester.tap(find.byTooltip('Tools').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select multiple'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Select all'));
      await tester.pumpAndSettle();
      expect(container.read(selectedItemIdsProvider), hasLength(5));
      expect(
        container.read(selectedItemIdsProvider),
        isNot(contains('sample-code')),
      );
      await tester.tap(find.byKey(const ValueKey('nav-0')));
      await tester.pump();
      expect(container.read(isMultiSelectProvider), isFalse);
      expect(container.read(selectedItemIdsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('narrow phone with larger text remains usable', (tester) async {
    await launch(tester, size: const Size(320, 780), scale: 1.5);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('vault-search')),
      'no-match',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('favorites remains an explicit filter', (tester) async {
    final container = await launch(tester);
    await tester.tap(find.byTooltip('Favorites only'));
    await tester.pumpAndSettle();
    expect(container.read(showFavoritesOnlyProvider), isTrue);
    expect(find.text('Paper & ink'), findsNothing);
    await tester.tap(find.byTooltip('Favorites only'));
    await tester.pumpAndSettle();
    expect(find.text('Paper & ink'), findsOneWidget);
  });
}
