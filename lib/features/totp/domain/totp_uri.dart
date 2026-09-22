/// A validated single-account provisioning URI supported by our TOTP engine.
class TotpUri {
  const TotpUri({
    required this.issuer,
    required this.account,
    required this.secret,
    required this.period,
  });

  final String issuer;
  final String account;
  final String secret;
  final int period;

  static String normalizeSecret(String value) {
    final secret = value.replaceAll(RegExp(r'\s'), '').toUpperCase();
    final unpadded = secret.replaceFirst(RegExp(r'=+$'), '');
    if (!RegExp(r'^[A-Z2-7]+={0,6}$').hasMatch(secret) ||
        !{0, 2, 4, 5, 7}.contains(unpadded.length % 8) ||
        (secret.contains('=') && secret.length % 8 != 0)) {
      throw const FormatException('Invalid TOTP secret');
    }
    return unpadded;
  }

  static TotpUri parse(String input) {
    // Never include input in exceptions: provisioning URIs contain secrets.
    try {
      final uri = Uri.parse(input.trim());
      if (uri.scheme != 'otpauth' ||
          uri.host != 'totp' ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.hasFragment ||
          uri.pathSegments.length != 1) {
        throw const FormatException();
      }
      final params = uri.queryParameters;
      if (uri.queryParametersAll.values.any((values) => values.length != 1)) {
        throw const FormatException();
      }
      if ((params['algorithm'] ?? 'SHA1').toUpperCase() != 'SHA1' ||
          (params['digits'] ?? '6') != '6' ||
          params.containsKey('counter')) {
        throw const UnsupportedTotpUri();
      }
      final period = int.tryParse(params['period'] ?? '30');
      if (period == null || period < 1 || period > 86400) {
        throw const FormatException();
      }
      final label = uri.pathSegments.single;
      final colon = label.indexOf(':');
      final labelIssuer = colon < 0 ? '' : label.substring(0, colon).trim();
      final account = (colon < 0 ? label : label.substring(colon + 1)).trim();
      final issuer = (params['issuer'] ?? labelIssuer).trim();
      if (account.isEmpty ||
          (labelIssuer.isNotEmpty && issuer != labelIssuer)) {
        throw const FormatException();
      }
      return TotpUri(
        issuer: issuer.isEmpty ? account : issuer,
        account: account,
        secret: normalizeSecret(params['secret'] ?? ''),
        period: period,
      );
    } on FormatException {
      throw const FormatException('Invalid TOTP QR code');
    }
  }
}

class UnsupportedTotpUri implements Exception {
  const UnsupportedTotpUri();
}
