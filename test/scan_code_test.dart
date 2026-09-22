import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:password/core/providers/app_providers.dart';
import 'package:password/features/sync/presentation/providers/sync_provider.dart';
import 'package:password/features/totp/presentation/providers/totp_provider.dart';
import 'package:password/features/totp/presentation/pages/scan_code_page.dart';
import 'package:password/features/totp/presentation/widgets/totp_item_card.dart';
import 'package:password/features/vault/domain/models/vault_item.dart';
import 'package:password/features/vault/presentation/providers/vault_provider.dart';

import 'support/vault_test_app.dart';

class _SavingVault extends MemoryVaultNotifier {
  _SavingVault() : super([]);
  int attempts = 0;
  final attemptedIds = <String>[];
  bool fail = false;
  @override
  Future<void> addItem(VaultItem item) async {
    attempts++;
    attemptedIds.add(item.id);
    if (fail) throw StateError('Synthetic write failure');
    state = AsyncData([...state.requireValue, item]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'dev.steenbakker.mobile_scanner/scanner/method',
  );
  const events = MethodChannel('dev.steenbakker.mobile_scanner/scanner/event');
  const orientation = MethodChannel(
    'dev.steenbakker.mobile_scanner/scanner/deviceOrientation',
  );
  const payload =
      'otpauth://totp/Acme:alex%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Acme&period=60';
  late List<String> calls;
  bool denied = false;
  bool unavailable = false;

  setUp(() {
    initializeVaultFixtureStorage();
    calls = [];
    denied = false;
    unavailable = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'state':
          return denied ? 2 : 1;
        case 'request':
          return !denied;
        case 'start':
          if (unavailable) throw PlatformException(code: 'camera_error');
          return {
            'textureId': 1,
            'handlesCropAndRotation': true,
            'naturalDeviceOrientation': 'PORTRAIT_UP',
            'sensorOrientation': 90,
            'cameraDirection': 1,
            'size': {'width': 640.0, 'height': 480.0},
          };
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(orientation, (_) async => null);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final item in [channel, events, orientation]) {
      messenger.setMockMethodCallHandler(item, null);
    }
  });

  Future<_SavingVault> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notifier = _SavingVault();
    final container = ProviderContainer(
      overrides: [
        vaultItemsProvider.overrideWith((_) => notifier),
        syncStatusProvider.overrideWith((_) => const Stream<bool>.empty()),
        tickerProvider.overrideWith((_) => const Stream<int>.empty()),
        sharedVaultsProvider.overrideWith((_) async => []),
      ],
    );
    container.read(selectedTabProvider.notifier).state = 0;
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const VaultTestApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    return notifier;
  }

  void detect(WidgetTester tester, String value) {
    tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
      BarcodeCapture(
        barcodes: [Barcode(rawValue: value, format: BarcodeFormat.qrCode)],
      ),
    );
  }

  void testOnPhones(String description, WidgetTesterCallback callback) {
    testWidgets(
      description,
      callback,
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testOnPhones('scan reviews fields, preserves period, and saves only once', (
    tester,
  ) async {
    final vault = await launch(tester);
    await tester.tap(find.byKey(const ValueKey('scan-totp')));
    await tester.pumpAndSettle();
    detect(tester, payload);
    detect(tester, payload);
    await tester.pumpAndSettle();
    expect(find.byType(ScanCodePage), findsNothing);
    expect(find.text('Acme'), findsOneWidget);
    expect(find.text('alex@example.com'), findsOneWidget);
    expect(vault.attempts, 0);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(vault.attempts, 1);
    expect(vault.state.requireValue.single.period, 60);
    expect(vault.state.requireValue.single.secret, 'JBSWY3DPEHPK3PXP');
    expect(find.byType(TotpItemCard), findsOneWidget);
    expect(calls, contains('stop'));
    await tester.pumpWidget(const SizedBox());
  });

  testOnPhones('invalid scan can recover and cancel keeps manual fields', (
    tester,
  ) async {
    final vault = await launch(tester);
    await tester.enterText(find.byType(TextField).at(1), 'Manual account');
    await tester.tap(find.byKey(const ValueKey('scan-totp')));
    await tester.pumpAndSettle();
    detect(tester, 'https://example.com');
    await tester.pump();
    expect(find.textContaining('not a valid authenticator'), findsOneWidget);
    detect(tester, '$payload&digits=8');
    await tester.pump();
    expect(find.textContaining('Only single-account TOTP'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Manual account'), findsOneWidget);
    expect(vault.attempts, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testOnPhones('failed save keeps scanned data for retry', (tester) async {
    final vault = await launch(tester);
    vault.fail = true;
    await tester.tap(find.byKey(const ValueKey('scan-totp')));
    await tester.pumpAndSettle();
    detect(tester, payload);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save the code'), findsOneWidget);
    expect(find.text('Acme'), findsOneWidget);
    vault.fail = false;
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();
    expect(vault.state.requireValue, hasLength(1));
    expect(vault.attemptedIds.toSet(), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testOnPhones('permission denial is readable and retry starts camera', (
    tester,
  ) async {
    denied = true;
    await launch(tester);
    await tester.tap(find.byKey(const ValueKey('scan-totp')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Camera access is denied'), findsOneWidget);
    denied = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Camera access is denied'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    final starts = calls.where((call) => call == 'start').length;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'start').length, starts + 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testOnPhones('camera failure permits returning to manual entry', (
    tester,
  ) async {
    unavailable = true;
    await launch(tester);
    await tester.tap(find.byKey(const ValueKey('scan-totp')));
    await tester.pumpAndSettle();
    expect(find.textContaining('camera could not start'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scan-totp')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
