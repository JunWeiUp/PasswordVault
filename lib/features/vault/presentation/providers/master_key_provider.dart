import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import '../../../../core/security/encryption_service.dart';

// In-memory cache for the derived key to avoid re-calculating it unnecessarily
List<int>? _cachedDerivedKey;

class MasterPasswordState {
  final String? password;
  final bool isBiometricEnabled;
  final bool hasMasterPassword;
  final bool isAuthenticated;

  MasterPasswordState({
    this.password,
    this.isBiometricEnabled = false,
    this.hasMasterPassword = false,
    this.isAuthenticated = false,
  });

  MasterPasswordState copyWith({
    String? password,
    bool? isBiometricEnabled,
    bool? hasMasterPassword,
    bool? isAuthenticated,
  }) {
    return MasterPasswordState(
      password: password ?? this.password,
      isBiometricEnabled: isBiometricEnabled ?? this.isBiometricEnabled,
      hasMasterPassword: hasMasterPassword ?? this.hasMasterPassword,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
    );
  }
}

final masterPasswordProvider = StateNotifierProvider<MasterPasswordNotifier, MasterPasswordState>((ref) {
  return MasterPasswordNotifier();
});

class MasterPasswordNotifier extends StateNotifier<MasterPasswordState> {
  MasterPasswordNotifier() : super(MasterPasswordState()) {
    _loadFromPrefs();
  }

  static const _passwordKey = 'saved_master_password';
  static const _biometricKey = 'biometric_enabled';

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final password = prefs.getString(_passwordKey);
    final isBiometricEnabled = prefs.getBool(_biometricKey) ?? false;
    
    state = state.copyWith(
      password: password,
      hasMasterPassword: password != null,
      isBiometricEnabled: isBiometricEnabled,
    );
  }

  Future<void> setPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_passwordKey, password);
    _cachedDerivedKey = null;
    state = state.copyWith(
      password: password,
      hasMasterPassword: true,
      isAuthenticated: true,
    );
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, enabled);
    state = state.copyWith(isBiometricEnabled: enabled);
  }

  void setAuthenticated(bool authenticated) {
    state = state.copyWith(isAuthenticated: authenticated);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_passwordKey);
    await prefs.remove(_biometricKey);
    _cachedDerivedKey = null;
    state = MasterPasswordState();
  }
}

final masterKeyProvider = FutureProvider<SecretKey?>((ref) async {
  final masterState = ref.watch(masterPasswordProvider);
  final password = masterState.password;
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
