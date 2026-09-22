import 'package:flutter_test/flutter_test.dart';
import 'package:password/features/totp/domain/totp_uri.dart';

void main() {
  const key = 'JBSWY3DPEHPK3PXP';
  test('parses encoded labels once, normalizes keys, and retains period', () {
    final result = TotpUri.parse(
      'otpauth://totp/Acme%20Co:alex%2B100%25%40example.com'
      '?secret=jbswy3dpehpk3pxp&issuer=Acme%20Co&period=60',
    );
    expect(result.issuer, 'Acme Co');
    expect(result.account, 'alex+100%@example.com');
    expect(result.secret, key);
    expect(result.period, 60);
  });

  test('accepts defaults and issuer-less labels', () {
    final result = TotpUri.parse('otpauth://totp/alex?secret=$key');
    expect(result.issuer, 'alex');
    expect(result.account, 'alex');
    expect(result.period, 30);
    expect(TotpUri.normalizeSecret('my======'), 'MY');
  });

  for (final suffix in [
    'algorithm=SHA256',
    'algorithm=SHA512',
    'digits=8',
    'counter=1',
  ]) {
    test('rejects unsupported parameters: $suffix', () {
      expect(
        () => TotpUri.parse('otpauth://totp/Acme:alex?secret=$key&$suffix'),
        throwsA(isA<UnsupportedTotpUri>()),
      );
    });
  }

  for (final value in [
    'https://example.com',
    'otpauth://hotp/alex?secret=$key&counter=1',
    'otpauth-migration://offline?data=example',
    'otpauth://totp/alex',
    'otpauth://totp/alex?secret=ABC0189',
    'otpauth://totp/alex?secret=A',
    'otpauth://totp/alex?secret=$key&secret=$key',
    'otpauth://totp/alex?secret=$key&period=0',
    'otpauth://totp/alex?secret=$key&period=-1',
    'otpauth://totp/alex?secret=$key&period=abc',
    'otpauth://totp/alex?secret=$key&period=99999999999999',
    'otpauth://totp/Acme:alex?secret=$key&issuer=Other',
    'otpauth://totp/?secret=$key',
    'otpauth://totp/Acme:?secret=$key',
    'otpauth://totp/a/b?secret=$key',
    'otpauth://totp/alex?secret=$key#fragment',
  ]) {
    test('rejects malformed input without leaking payload ($value)', () {
      expect(() => TotpUri.parse(value), throwsFormatException);
      try {
        TotpUri.parse(value);
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains(key)));
        expect(error.source, isNull);
      }
    });
  }
}
