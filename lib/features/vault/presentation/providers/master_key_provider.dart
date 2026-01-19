import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import '../../../../core/security/encryption_service.dart';

// In-memory cache for the derived key to avoid re-calculating it unnecessarily
List<int>? _cachedDerivedKey;

final masterPasswordProvider = StateNotifierProvider<MasterPasswordNotifier, String?>((ref) {
  return MasterPasswordNotifier();
});

class MasterPasswordNotifier extends StateNotifier<String?> {
  MasterPasswordNotifier() : super(null) {
    _loadFromPrefs();
  }

  static const _key = 'saved_master_password';

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // 注意：实际应用中不应明文存储主密码，这里为了演示和 Web 刷新体验暂时保留
    state = prefs.getString(_key) ?? "default_password";
  }

  Future<void> setPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, password);
    // 设置新密码时清空密钥缓存
    _cachedDerivedKey = null;
    state = password;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    _cachedDerivedKey = null;
    state = null;
  }
}

final masterKeyProvider = FutureProvider<SecretKey?>((ref) async {
  final password = ref.watch(masterPasswordProvider);
  if (password == null) return null;

  // 1. 尝试从内存缓存获取已计算好的密钥
  if (_cachedDerivedKey != null) {
    return SecretKey(_cachedDerivedKey!);
  }

  final encryptionService = EncryptionService();
  final prefs = await SharedPreferences.getInstance();

  List<int> salt;
  final saltBase64 = prefs.getString('master_key_salt');

  if (saltBase64 != null) {
    salt = base64.decode(saltBase64);
  } else {
    final random = Random.secure();
    salt = List<int>.generate(16, (i) => random.nextInt(256));
    await prefs.setString('master_key_salt', base64.encode(salt));
  }

  // 2. 计算密钥（耗时操作）
  final key = await encryptionService.deriveKey(password, salt);
  
  // 3. 存入缓存
  _cachedDerivedKey = await key.extractBytes();

  return key;
});
