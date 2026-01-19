import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    colorSchemeSeed: Colors.blueAccent,
    textTheme: const TextTheme(
      // 用于 2FA 动态码：等宽、大字号
      displayLarge: TextStyle(
        fontSize: 38,
        fontWeight: FontWeight.w500,
        fontFamily: 'monospace',
        letterSpacing: 4,
      ),
      // 用于服务名
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      // 用于用户名
      bodyMedium: TextStyle(fontSize: 14, color: Colors.grey),
    ),
  );

  static ThemeData get dark => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorSchemeSeed: Colors.blueAccent,
    textTheme: const TextTheme(
      displayLarge: TextStyle(
        fontSize: 38,
        fontWeight: FontWeight.w500,
        fontFamily: 'monospace',
        letterSpacing: 4,
      ),
      titleMedium: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      bodyMedium: TextStyle(fontSize: 14, color: Colors.grey),
    ),
  );
}
