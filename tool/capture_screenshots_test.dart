// Run explicitly: flutter test --update-goldens tool/capture_screenshots_test.dart
// Captures real application widgets with fictional, memory-only fixture data.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/features/vault/presentation/pages/lock_page.dart';
import 'package:password/features/vault/presentation/pages/password_generator_page.dart';
import '../test/support/vault_test_app.dart';

Future<void> loadScreenshotFonts() async {
  final config = File('.dart_tool/package_config.json');
  final packages = (jsonDecode(config.readAsStringSync())['packages'] as List);
  final flutter = packages.firstWhere((p) => p['name'] == 'flutter');
  final packageDirectory = config.uri.resolve(flutter['rootUri'] as String);
  final root = Directory.fromUri(packageDirectory).uri.resolve('../../');
  for (final font in [
    ('Roboto', 'Roboto-Regular.ttf'),
    ('Ahem', 'Roboto-Regular.ttf'),
    ('Roboto', 'Roboto-Medium.ttf'),
    ('Roboto', 'Roboto-Bold.ttf'),
    ('MaterialIcons', 'MaterialIcons-Regular.otf'),
  ]) {
    final loader = FontLoader(font.$1)
      ..addFont(
        File.fromUri(
          root.resolve('bin/cache/artifacts/material_fonts/${font.$2}'),
        ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    await loader.load();
  }
  final mono = FontLoader('monospace')
    ..addFont(
      File(
        'docs/images/fonts/RobotoMono.ttf',
      ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
    );
  await mono.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadScreenshotFonts);
  for (final shot in [
    (
      name: 'vault-desktop',
      size: const Size(1280, 900),
      dark: false,
      home: null,
    ),
    (name: 'vault-mobile', size: const Size(390, 844), dark: false, home: null),
    (name: 'vault-dark', size: const Size(390, 844), dark: true, home: null),
    (
      name: 'lock',
      size: const Size(390, 900),
      dark: false,
      home: const LockPage(),
    ),
    (
      name: 'generator',
      size: const Size(720, 1040),
      dark: false,
      home: const PasswordGeneratorPage(),
    ),
  ]) {
    testWidgets('capture ${shot.name}', (tester) async {
      initializeVaultFixtureStorage();
      tester.view.physicalSize = shot.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = createVaultFixture();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: const ValueKey('capture'),
            child: VaultTestApp(home: shot.home, dark: shot.dark),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('capture')),
        matchesGoldenFile('../docs/images/${shot.name}.png'),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
