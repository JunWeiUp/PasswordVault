import 'package:cryptography/cryptography.dart';
import 'dart:convert';

class EncryptionService {
  final _cipher = AesGcm.with256bits();
  
  // 使用 Argon2id 从主密码派生密钥 (Key Derivation)
  Future<SecretKey> deriveKey(
    String password, 
    List<int> salt, {
    int iterations = 2,
    int memory = 32 * 1024,
    int parallelism = 1,
  }) async {
    final algorithm = Argon2id(
      parallelism: parallelism,
      memory: memory,
      iterations: iterations,
      hashLength: 32,
    );
    return algorithm.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
  }

  // 极简密钥派生：直接使用 SHA-256 哈希密码，确保跨平台绝对一致
  Future<SecretKey> deriveKeySimple(String password) async {
    final bytes = utf8.encode(password);
    final hash = await Sha256().hash(bytes);
    return SecretKey(hash.bytes);
  }

  // 加密：返回密文 + Nonce
  Future<List<int>> encrypt(String data, SecretKey key) async {
    final clearText = utf8.encode(data);
    final secretBox = await _cipher.encrypt(clearText, secretKey: key);
    return secretBox.concatenation();
  }

  // 解密
  Future<String> decrypt(List<int> encryptedData, SecretKey key) async {
    final secretBox = SecretBox.fromConcatenation(
      encryptedData,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    final clearText = await _cipher.decrypt(secretBox, secretKey: key);
    return utf8.decode(clearText);
  }
}
