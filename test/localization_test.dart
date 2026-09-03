import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/core/l10n/l10n.dart';
import 'package:password/features/vault/presentation/pages/lock_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalizedLockApp extends ConsumerWidget {
  const LocalizedLockApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      locale: ref.watch(localeProvider),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const LockPage(),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('lock screen defaults to English and switches to Chinese', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(child: LocalizedLockApp()));
    await tester.pumpAndSettle();
    expect(find.text('Set master password'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文').last);
    await tester.pumpAndSettle();
    expect(find.text('设置主密码'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);
    expect(find.text('Set master password'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString(
        LocaleNotifier.preferenceKey,
      ),
      'zh',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved Chinese preference is restored on startup', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocaleNotifier.preferenceKey: 'zh',
    });
    await tester.pumpWidget(const ProviderScope(child: LocalizedLockApp()));
    await tester.pumpAndSettle();
    expect(find.text('设置主密码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('unsupported saved locale falls back to English', () async {
    SharedPreferences.setMockInitialValues({
      LocaleNotifier.preferenceKey: 'xx',
    });
    final notifier = LocaleNotifier();
    await notifier.ready;
    expect(notifier.state, const Locale('en'));
    await notifier.setLanguage('xx');
    expect(notifier.state, const Locale('en'));
    notifier.dispose();
  });
}
