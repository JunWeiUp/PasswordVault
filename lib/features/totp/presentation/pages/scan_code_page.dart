import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:password/core/l10n/l10n.dart';
import '../../domain/totp_uri.dart';

class ScanCodePage extends StatefulWidget {
  const ScanCodePage({super.key});

  @override
  State<ScanCodePage> createState() => _ScanCodePageState();
}

class _ScanCodePageState extends State<ScanCodePage>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _completed = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The permission prompt itself can interrupt the app before setup finishes.
    if (_completed || !_controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed) {
      _startCamera();
    } else if (state == AppLifecycleState.inactive) {
      unawaited(_controller.stop());
    }
  }

  void _startCamera() {
    if (!_completed && !_controller.value.isStarting) {
      unawaited(_controller.start());
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_completed || !mounted) return;
    String? message;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      try {
        final result = TotpUri.parse(raw);
        // Lock synchronously: a camera can report the same code in many frames.
        _completed = true;
        unawaited(_controller.stop());
        Navigator.of(context).pop(result);
        return;
      } on UnsupportedTotpUri {
        message = tr.unsupportedTotpQr;
      } on FormatException {
        message ??= tr.invalidTotpQr;
      }
    }
    if (message != null && message != _message) {
      setState(() => _message = message);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.scanCode)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) => Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        const Icon(Icons.no_photography_outlined, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          error.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? tr.cameraPermissionRequired
                              : tr.cameraUnavailable,
                          style: const TextStyle(fontSize: 20, height: 1.75),
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _startCamera,
                          child: Text(
                            tr.retryAction,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Flexible(
              flex: 0,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .35,
                ),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _message ?? tr.scanCodeInstructions,
                    style: const TextStyle(fontSize: 20, height: 1.75),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
