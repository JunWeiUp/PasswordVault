import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cryptography/cryptography.dart';
import '../../../../core/security/encryption_service.dart';

import '../../../../core/extension/extension_helper.dart';

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
  static const _lastAuthTimeKey = 'last_auth_time';
  static const _cachedMasterKey = 'cached_master_key';
  static const _authTimeout = Duration(minutes: 10);

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final password = prefs.getString(_passwordKey);
    final isBiometricEnabled = prefs.getBool(_biometricKey) ?? false;
    
    bool isAuthenticated = false;
    if (password != null) {
      final lastAuthStr = prefs.getString(_lastAuthTimeKey);
      if (lastAuthStr != null) {
        final lastAuth = DateTime.tryParse(lastAuthStr);
        if (lastAuth != null && DateTime.now().difference(lastAuth) < _authTimeout) {
          isAuthenticated = true;
          debugPrint('🔓 Auto-authenticated within 10 minutes');
        }
      }
    }

    state = state.copyWith(
      password: password,
      hasMasterPassword: password != null,
      isBiometricEnabled: isBiometricEnabled,
      isAuthenticated: isAuthenticated,
    );
  }

  Future<void> setPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_passwordKey, password);
    await prefs.setString(_lastAuthTimeKey, DateTime.now().toIso8601String());
    await prefs.remove(_cachedMasterKey);
    _cachedDerivedKey = null;
    if (ExtensionHelper.isExtension) {
      await ExtensionHelper.clearCachedMasterKey();
    }
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

  Future<void> setAuthenticated(bool authenticated) async {
    if (authenticated) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastAuthTimeKey, DateTime.now().toIso8601String());
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastAuthTimeKey);
      await prefs.remove(_cachedMasterKey);
    }
    state = state.copyWith(isAuthenticated: authenticated);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_passwordKey);
    await prefs.remove(_biometricKey);
    await prefs.remove(_cachedMasterKey);
    _cachedDerivedKey = null;
    if (ExtensionHelper.isExtension) {
      await ExtensionHelper.clearCachedMasterKey();
    }
    state = MasterPasswordState();
  }
}

final masterKeySaltProvider = FutureProvider<List<int>?>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final saltBase64 = prefs.getString('master_key_salt');
  if (saltBase64 != null) {
    return base64.decode(saltBase64);
  }
  return null;
});

final masterKeyProvider = FutureProvider<SecretKey?>((ref) async {
  final masterState = ref.watch(masterPasswordProvider);
  final password = masterState.password;
  if (password == null || !masterState.isAuthenticated) return null;

  // 1. 尝试从内存缓存获取已计算好的密钥
  if (_cachedDerivedKey != null) {
    return SecretKey(_cachedDerivedKey!);
  }

  // 1.1 尝试从插件后台 Service Worker 获取缓存的密钥
  if (ExtensionHelper.isExtension) {
    final cachedBase64 = await ExtensionHelper.getCachedMasterKey();
    if (cachedBase64 != null) {
      debugPrint('🔑 Retrieved master key from extension background');
      _cachedDerivedKey = base64.decode(cachedBase64);
      return SecretKey(_cachedDerivedKey!);
    }
  }

  final encryptionService = EncryptionService();
  final prefs = await SharedPreferences.getInstance();

  final lastAuthStr = prefs.getString(MasterPasswordNotifier._lastAuthTimeKey);
  if (lastAuthStr != null) {
    final lastAuth = DateTime.tryParse(lastAuthStr);
    if (lastAuth != null && DateTime.now().difference(lastAuth) < MasterPasswordNotifier._authTimeout) {
      final cachedBase64 = prefs.getString(MasterPasswordNotifier._cachedMasterKey);
      if (cachedBase64 != null) {
        _cachedDerivedKey = base64.decode(cachedBase64);
        return SecretKey(_cachedDerivedKey!);
      }
    }
  }

  List<int> salt;
  final saltBase64 = prefs.getString('master_key_salt');

  if (saltBase64 != null) {
    salt = base64.decode(saltBase64);
  } else {
    final random = Random.secure();
    salt = List<int>.generate(16, (i) => random.nextInt(256));
    await prefs.setString('master_key_salt', base64.encode(salt));
  }

  // 2. 计算密钥（耗时操作：Argon2id）
  debugPrint('⏳ Deriving master key via Argon2id...');
  final key = await encryptionService.deriveKey(password, salt);
  
  // 3. 存入缓存
  final bytes = await key.extractBytes();
  _cachedDerivedKey = bytes;
  await prefs.setString(MasterPasswordNotifier._cachedMasterKey, base64.encode(bytes));

  // 3.1 同步到插件后台，以便下次秒开
  if (ExtensionHelper.isExtension) {
    await ExtensionHelper.cacheMasterKey(base64.encode(bytes));
    debugPrint('🔑 Master key synced to extension background');
  }

  return key;
});
