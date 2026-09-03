import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

/// Uses flutter_secure_storage (iOS Keychain / Android Keystore) on mobile,
/// and falls back to SharedPreferences on web/extension where secure storage
/// is unreliable (no real OS keystore, data lost on extension reinstall).
class SecureStorageService {
  static SecureStorageService? _instance;
  FlutterSecureStorage? _storage;

  SecureStorageService._() {
    if (!kIsWeb) {
      _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      );
    }
  }

  factory SecureStorageService() {
    _instance ??= SecureStorageService._();
    return _instance!;
  }

  bool get _useNativeStorage => !kIsWeb && _storage != null;

  Future<String?> read(String key) async {
    if (_useNativeStorage) {
      return _storage!.read(key: key);
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  Future<void> write(String key, String value) async {
    if (_useNativeStorage) {
      return _storage!.write(key: key, value: value);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  Future<void> delete(String key) async {
    if (_useNativeStorage) {
      return _storage!.delete(key: key);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }

  Future<bool> containsKey(String key) async {
    if (_useNativeStorage) {
      return _storage!.containsKey(key: key);
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(key);
  }

  Future<void> deleteAll() async {
    if (_useNativeStorage) {
      return _storage!.deleteAll();
    }
  }
}
