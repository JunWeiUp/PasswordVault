import 'dart:convert';

import 'package:base32/base32.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/features/totp/domain/totp_engine.dart';

void main() {
  test('uses the stored refresh interval with RFC 4226 counter vectors', () {
    // Public RFC 4226 test vector, encoded here rather than stored as a key.
    final secret = base32.encode(utf8.encode('12345678901234567890'));
    final time = DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true);
    expect(TotpEngine.generateCode(secret, at: time), '287 082');
    expect(TotpEngine.generateCode(secret, interval: 60, at: time), '755 224');
    expect(
      TotpEngine.generateCode(
        secret,
        interval: 60,
        at: DateTime.fromMillisecondsSinceEpoch(60000, isUtc: true),
      ),
      '287 082',
    );
  });
}
