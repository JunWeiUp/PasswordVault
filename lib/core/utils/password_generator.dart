import 'dart:math';
import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/foundation.dart';

class PasswordGenerator {
  static const String uppercaseChars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const String lowercaseChars = 'abcdefghijklmnopqrstuvwxyz';
  static const String numberChars = '0123456789';
  static const String symbolChars = '!@#\$%^&*()_+-=[]{}|;:,.<>?';

  static String generate({
    int length = 16,
    bool useUppercase = true,
    bool useLowercase = true,
    bool useNumbers = true,
    bool useSymbols = true,
  }) {
    String allowedChars = '';
    if (useUppercase) allowedChars += uppercaseChars;
    if (useLowercase) allowedChars += lowercaseChars;
    if (useNumbers) allowedChars += numberChars;
    if (useSymbols) allowedChars += symbolChars;

    if (allowedChars.isEmpty) {
      return '';
    }

    final random = Random.secure();
    return List.generate(length, (index) {
      return allowedChars[random.nextInt(allowedChars.length)];
    }).join();
  }

  static Future<String> generateMnemonic() async {
    // 使用 compute 异步生成，确保不阻塞 UI 线程
    return await compute((_) => bip39.generateMnemonic(), null);
  }
}
