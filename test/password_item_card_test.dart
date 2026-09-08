import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/core/l10n/l10n.dart';
import 'package:password/features/vault/domain/models/vault_item.dart';
import 'package:password/features/vault/presentation/widgets/password_item_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/vault_test_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> launch(
    WidgetTester tester, {
    required VaultItem item,
    List<VaultItem>? items,
    Size size = const Size(700, 700),
    double textScale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = createVaultFixture(items: items ?? [item]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: VaultTestApp(
          textScale: textScale,
          dark: dark,
          home: Scaffold(
            // The production vault puts cards in a scrolling collection.
            body: SingleChildScrollView(child: PasswordItemCard(item: item)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void mockClipboard(Future<void> Function(String value) write) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final arguments = call.arguments as Map<dynamic, dynamic>;
        await write(arguments['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  testWidgets(
    'default and additional account copy the chosen password after completion',
    (tester) async {
      final item = VaultItem(
        id: 'multi-account-fixture',
        type: VaultItemType.password,
        title: 'Fictional service',
        username: 'default@example.com',
        password: 'Fixture-default!824',
        accounts: [
          AccountEntry(
            id: 'work-account',
            label: 'Work',
            username: 'work@example.com',
            password: 'Fixture-work!531',
          ),
        ],
      );
      final pendingWrite = Completer<void>();
      final copiedValues = <String>[];
      mockClipboard((value) async {
        copiedValues.add(value);
        if (copiedValues.length == 1) await pendingWrite.future;
      });
      await launch(tester, item: item);

      await tester.tap(find.byTooltip('Copy password'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Default: default@example.com'));
      await tester.pumpAndSettle();
      expect(copiedValues, ['Fixture-default!824']);
      expect(find.text('Password copied for Default account'), findsNothing);

      pendingWrite.complete();
      await tester.pumpAndSettle();
      expect(find.text('Password copied for Default account'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy password'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Work: work@example.com'));
      await tester.pumpAndSettle();
      expect(copiedValues, ['Fixture-default!824', 'Fixture-work!531']);
      expect(find.text('Password copied for Work'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clipboard failure shows no success and allows a retry', (
    tester,
  ) async {
    final item = VaultItem(
      id: 'clipboard-retry-fixture',
      type: VaultItemType.password,
      title: 'Fictional account',
      username: 'fixture@example.com',
      password: 'Fixture-password!519',
    );
    var attempts = 0;
    final copiedValues = <String>[];
    mockClipboard((value) async {
      attempts++;
      if (attempts == 1) {
        throw PlatformException(code: 'clipboard_unavailable');
      }
      copiedValues.add(value);
    });
    await launch(tester, item: item);
    await tester.tap(find.byTooltip('Copy password'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(copiedValues, isEmpty);
    expect(find.text('Could not copy. Please try again.'), findsOneWidget);
    expect(find.text('Password copied'), findsNothing);

    await tester.tap(find.byTooltip('Copy password'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(copiedValues, ['Fixture-password!519']);
    expect(find.text('Password copied'), findsOneWidget);
    expect(find.text('Could not copy. Please try again.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long Chinese content and health labels wrap at narrow widths', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocaleNotifier.preferenceKey: 'zh',
    });
    final item = VaultItem(
      id: 'long-title-fixture',
      type: VaultItemType.password,
      title: '这是一个需要完整显示的中文工作账号名称以及相关说明',
      username: 'long-fictional-account-name@example.com',
      password: '1234',
      tags: ['工作资料与协作平台', '家庭共同使用的测试账号', '很长的中文标签需要自然换行'],
      passwordDuration: 1,
      passwordLastChanged: DateTime(2020),
      accounts: [
        AccountEntry(
          id: 'secondary-fixture',
          username: 'other@example.com',
          password: 'Fixture-other!829',
        ),
      ],
    );
    final other = VaultItem(
      id: 'reused-password-fixture',
      type: VaultItemType.password,
      title: 'Other fictional account',
      username: 'other@example.com',
      password: '1234',
    );
    await launch(
      tester,
      item: item,
      items: [item, other],
      size: const Size(320, 780),
      textScale: 1.8,
      dark: true,
    );
    expect(find.text(item.title), findsOneWidget);
    expect(find.text('弱密码'), findsOneWidget);
    expect(find.text('重复使用'), findsOneWidget);
    for (final tag in item.tags) {
      expect(find.text(tag), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    final copyAction = find.byTooltip('复制密码');
    await tester.ensureVisible(copyAction);
    await tester.pumpAndSettle();
    expect(tester.getSize(copyAction).height, greaterThanOrEqualTo(48));
    await tester.tap(copyAction);
    await tester.pumpAndSettle();
    expect(
      find.text('默认: long-fictional-account-name@example.com'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
