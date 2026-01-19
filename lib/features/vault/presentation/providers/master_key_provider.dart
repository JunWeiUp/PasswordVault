import 'dart:convert';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import '../../../../core/security/encryption_service.dart';
import 'dart:html' as html; // 用于 sessionStorage

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
    html.window.sessionStorage.remove('derived_master_key');
    state = password;
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    html.window.sessionStorage.remove('derived_master_key');
    state = null;
  }
}

final masterKeyProvider = FutureProvider<SecretKey?>((ref) async {
  final password = ref.watch(masterPasswordProvider);
  if (password == null) return null;

  // 1. 尝试从 sessionStorage 获取已计算好的密钥（F5 刷新后极速恢复）
  final cachedKeyBase64 = html.window.sessionStorage['derived_master_key'];
  if (cachedKeyBase64 != null) {
    return SecretKey(base64.decode(cachedKeyBase64));
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
  final keyBytes = await key.extractBytes();
  html.window.sessionStorage['derived_master_key'] = base64.encode(keyBytes);

  return key;
});
