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
  final int autoLockMinutes;
  final String? userPublicKey; // Base64 encoded public key
  final String? encryptedUserPrivateKey; // Base64 encoded, encrypted by master key

  MasterPasswordState({
    this.password,
    this.isBiometricEnabled = false,
    this.hasMasterPassword = false,
    this.isAuthenticated = false,
    this.autoLockMinutes = 10,
    this.userPublicKey,
    this.encryptedUserPrivateKey,
  });

  MasterPasswordState copyWith({
    String? password,
    bool? isBiometricEnabled,
    bool? hasMasterPassword,
    bool? isAuthenticated,
    int? autoLockMinutes,
    String? userPublicKey,
    String? encryptedUserPrivateKey,
  }) {
    return MasterPasswordState(
      password: password ?? this.password,
      isBiometricEnabled: isBiometricEnabled ?? this.isBiometricEnabled,
      hasMasterPassword: hasMasterPassword ?? this.hasMasterPassword,
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      autoLockMinutes: autoLockMinutes ?? this.autoLockMinutes,
      userPublicKey: userPublicKey ?? this.userPublicKey,
      encryptedUserPrivateKey: encryptedUserPrivateKey ?? this.encryptedUserPrivateKey,
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
  static const _autoLockKey = 'auto_lock_minutes';
  static const _userPublicKey = 'user_public_key';
  static const _encryptedUserPrivateKey = 'encrypted_user_private_key';

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final password = prefs.getString(_passwordKey);
    final isBiometricEnabled = prefs.getBool(_biometricKey) ?? false;
    final autoLockMinutes = prefs.getInt(_autoLockKey) ?? 10;
    final userPubKey = prefs.getString(_userPublicKey);
    final encUserPrivKey = prefs.getString(_encryptedUserPrivateKey);
    
    bool isAuthenticated = false;
    if (password != null) {
      final lastAuthStr = prefs.getString(_lastAuthTimeKey);
      if (lastAuthStr != null) {
        final lastAuth = DateTime.tryParse(lastAuthStr);
        if (lastAuth != null && DateTime.now().difference(lastAuth) < Duration(minutes: autoLockMinutes)) {
          isAuthenticated = true;
          debugPrint('🔓 Auto-authenticated within $autoLockMinutes minutes');
        }
      }
    }

    state = state.copyWith(
      password: password,
      hasMasterPassword: password != null,
      isBiometricEnabled: isBiometricEnabled,
      isAuthenticated: isAuthenticated,
      autoLockMinutes: autoLockMinutes,
      userPublicKey: userPubKey,
      encryptedUserPrivateKey: encUserPrivKey,
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
    
    // 生成用户密钥对
    final encryptionService = EncryptionService();
    final keyPair = await encryptionService.generateKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final privKeyBytes = await keyPair.extractPrivateKeyBytes();
    
    // 使用主密码派生的密钥加密私钥
    // 这里需要临时计算主密钥
    List<int> salt;
    final saltBase64 = prefs.getString('master_key_salt');
    if (saltBase64 != null) {
      salt = base64.decode(saltBase64);
    } else {
      final random = Random.secure();
      salt = List<int>.generate(16, (i) => random.nextInt(256));
      await prefs.setString('master_key_salt', base64.encode(salt));
    }
    
    final masterKey = await encryptionService.deriveKey(password, salt);
    final encryptedPrivKey = await encryptionService.encrypt(base64.encode(privKeyBytes), masterKey);
    
    final pubKeyBase64 = base64.encode(pubKey.bytes);
    final encPrivKeyBase64 = base64.encode(encryptedPrivKey);
    
    await prefs.setString(_userPublicKey, pubKeyBase64);
    await prefs.setString(_encryptedUserPrivateKey, encPrivKeyBase64);

    state = state.copyWith(
      password: password,
      hasMasterPassword: true,
      isAuthenticated: true,
      userPublicKey: pubKeyBase64,
      encryptedUserPrivateKey: encPrivKeyBase64,
    );
  }

  Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_biometricKey, enabled);
    state = state.copyWith(isBiometricEnabled: enabled);
  }

  Future<void> setAutoLockMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoLockKey, minutes);
    state = state.copyWith(autoLockMinutes: minutes);
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

  /// 确保用户密钥对已生成，如果不存在则自动生成
  Future<void> ensureUserKeyPair() async {
    if (state.userPublicKey != null && state.encryptedUserPrivateKey != null) {
      return;
    }

    final password = state.password;
    if (password == null || !state.isAuthenticated) {
      throw Exception('用户尚未认证，无法生成密钥对');
    }

    final encryptionService = EncryptionService();
    final prefs = await SharedPreferences.getInstance();

    // 1. 获取主密钥
    List<int> salt;
    final saltBase64 = prefs.getString('master_key_salt');
    if (saltBase64 != null) {
      salt = base64.decode(saltBase64);
    } else {
      final random = Random.secure();
      salt = List<int>.generate(16, (i) => random.nextInt(256));
      await prefs.setString('master_key_salt', base64.encode(salt));
    }
    
    final masterKey = await encryptionService.deriveKey(password, salt);

    // 2. 生成用户密钥对
    final keyPair = await encryptionService.generateKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final privKeyBytes = await keyPair.extractPrivateKeyBytes();
    
    // 3. 加密并存储
    final encryptedPrivKey = await encryptionService.encrypt(base64.encode(privKeyBytes), masterKey);
    final pubKeyBase64 = base64.encode(pubKey.bytes);
    final encPrivKeyBase64 = base64.encode(encryptedPrivKey);
    
    await prefs.setString(_userPublicKey, pubKeyBase64);
    await prefs.setString(_encryptedUserPrivateKey, encPrivKeyBase64);

    state = state.copyWith(
      userPublicKey: pubKeyBase64,
      encryptedUserPrivateKey: encPrivKeyBase64,
    );
    
    debugPrint('🔑 User key pair automatically generated');
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
    final autoLockMinutes = prefs.getInt(MasterPasswordNotifier._autoLockKey) ?? 10;
    
    if (lastAuth != null && DateTime.now().difference(lastAuth) < Duration(minutes: autoLockMinutes)) {
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

<<<<<<< Updated upstream
/// 提供所有可能的备选密钥，用于解密不同时期或不同方案加密的数据
final fallbackKeysProvider = FutureProvider<List<SecretKey>>((ref) async {
  final masterState = ref.watch(masterPasswordProvider);
  final password = masterState.password;
  if (password == null || !masterState.isAuthenticated) return [];

  final encryptionService = EncryptionService();
  
  // 方案 1: SHA-256 极简方案 (Version 3.0.0+)
  final simpleKey = await encryptionService.deriveKeySimple(password);
  
  // 方案 2: 标准固定盐值方案 (Version 2.0.0)
  final standardSalt = utf8.encode('SecurePass_Backup_Standard_Salt_2024');
  final standardBackupKey = await encryptionService.deriveKey(
    password, 
    standardSalt,
    iterations: 2,
    memory: 32 * 1024,
    parallelism: 1,
  );

  return [simpleKey, standardBackupKey];
=======
final userKeyPairProvider = FutureProvider<SimpleKeyPair?>((ref) async {
  final masterState = ref.watch(masterPasswordProvider);
  final masterKey = await ref.watch(masterKeyProvider.future);
  
  if (masterKey == null || masterState.encryptedUserPrivateKey == null) return null;
  
  final encryptionService = EncryptionService();
  try {
    final encryptedPrivKey = base64.decode(masterState.encryptedUserPrivateKey!);
    final decryptedPrivKeyBase64 = await encryptionService.decrypt(encryptedPrivKey, masterKey);
    final privKeyBytes = base64.decode(decryptedPrivKeyBase64);
    
    return await encryptionService.keyPairFromPrivateKey(privKeyBytes);
  } catch (e) {
    debugPrint('Failed to decrypt user key pair: $e');
    return null;
  }
>>>>>>> Stashed changes
});
