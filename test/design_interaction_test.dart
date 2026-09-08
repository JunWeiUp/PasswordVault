import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/core/l10n/l10n.dart';
import 'package:password/core/theme/app_theme.dart';
import 'package:password/features/vault/presentation/pages/lock_page.dart';
import 'package:password/features/vault/presentation/pages/password_generator_page.dart';
import 'package:password/features/vault/presentation/providers/master_key_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _DesignTestApp extends ConsumerWidget {
  const _DesignTestApp({
    required this.home,
    this.textScale = 1,
    this.dark = false,
  });

  final Widget home;
  final double textScale;
  final bool dark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
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
      home: home,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('setup validates confirmation and supports password visibility', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: _DesignTestApp(home: LockPage())),
    );
    await tester.pumpAndSettle();
    final password = find.byKey(const ValueKey('master-password'));
    final confirmation = find.byKey(const ValueKey('confirm-master-password'));
    await tester.enterText(password, 'example-password');
    await tester.ensureVisible(find.byTooltip('Show password').first);
    await tester.tap(find.byTooltip('Show password').first);
    await tester.pump();
    expect(tester.widget<TextField>(password).obscureText, isFalse);
    await tester.enterText(confirmation, 'different-password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(LockPage)),
    );
    expect(scope.read(masterPasswordProvider).hasMasterPassword, isFalse);

    await tester.enterText(confirmation, 'example-password');
    await tester.pump();
    expect(find.text('Passwords do not match.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incorrect password keeps vault locked and keyboard can retry', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({
      'saved_master_password': 'fixture-password',
    });
    await tester.pumpWidget(
      const ProviderScope(child: _DesignTestApp(home: LockPage())),
    );
    await tester.pumpAndSettle();
    final password = find.byKey(const ValueKey('master-password'));
    final scope = ProviderScope.containerOf(
      tester.element(find.byType(LockPage)),
    );
    await tester.enterText(password, 'incorrect');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Incorrect password'), findsOneWidget);
    expect(scope.read(masterPasswordProvider).isAuthenticated, isFalse);
    await tester.enterText(password, 'fixture-password');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(scope.read(masterPasswordProvider).isAuthenticated, isTrue);
    expect(find.text('Incorrect password'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow dark lock screen remains usable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const ProviderScope(
        child: _DesignTestApp(home: LockPage(), textScale: 1.8, dark: true),
      ),
    );
    await tester.pumpAndSettle();
    final submit = find.byKey(const ValueKey('unlock-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('Password cannot be empty.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('generator disables copy with no character types and recovers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const ProviderScope(
        child: _DesignTestApp(
          home: PasswordGeneratorPage(),
          textScale: 1.8,
          dark: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var index = 0; index < 4; index++) {
      final control = find.byType(SwitchListTile).at(index);
      await tester.ensureVisible(control);
      await tester.tap(control);
      await tester.pumpAndSettle();
    }
    final copy = find.byKey(const ValueKey('copy-password'));
    expect(tester.widget<FilledButton>(copy).onPressed, isNull);
    expect(find.byKey(const ValueKey('generated-password')), findsNothing);
    expect(find.text('Select at least one character type.'), findsOneWidget);

    // Enabling just digits must regenerate with that configuration.
    final digits = find.byType(SwitchListTile).at(2);
    await tester.ensureVisible(digits);
    await tester.tap(digits);
    await tester.pumpAndSettle();
    final result = tester.widget<SelectableText>(
      find.byKey(const ValueKey('generated-password')),
    );
    expect(result.data, matches(RegExp(r'^\d{16}$')));
    expect(tester.widget<FilledButton>(copy).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy confirms only after completion and allows failure retry', (
    tester,
  ) async {
    final clipboardWrite = Completer<void>();
    var attempts = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        attempts++;
        if (attempts == 1) {
          await clipboardWrite.future;
          throw PlatformException(code: 'clipboard_unavailable');
        }
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.pumpWidget(
      const ProviderScope(child: _DesignTestApp(home: PasswordGeneratorPage())),
    );
    await tester.pumpAndSettle();
    final copy = find.byKey(const ValueKey('copy-password'));
    await tester.tap(copy);
    await tester.pump();
    expect(attempts, 1);
    expect(tester.widget<FilledButton>(copy).onPressed, isNull);
    expect(find.text('Copied to clipboard'), findsNothing);
    clipboardWrite.complete();
    await tester.pumpAndSettle();
    expect(find.text('Could not copy. Please try again.'), findsOneWidget);
    expect(tester.widget<FilledButton>(copy).onPressed, isNotNull);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Copied to clipboard'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
