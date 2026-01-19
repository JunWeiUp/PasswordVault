import 'package:cryptography/cryptography.dart';
import 'dart:convert';

class EncryptionService {
  final _cipher = AesGcm.with256bits();
  
  // 使用 Argon2id 从主密码派生密钥 (Key Derivation)
  Future<SecretKey> deriveKey(String password, List<int> salt) async {
    final algorithm = Argon2id(
      parallelism: 2,
      memory: 64 * 1024, // 64MB
      iterations: 3,
      hashLength: 32,
    );
    return algorithm.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
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
