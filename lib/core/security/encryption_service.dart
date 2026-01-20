import 'package:cryptography/cryptography.dart';
import 'dart:convert';

class EncryptionService {
  final _cipher = AesGcm.with256bits();
  
  // 使用 Argon2id 从主密码派生密钥 (Key Derivation)
  Future<SecretKey> deriveKey(String password, List<int> salt) async {
    final algorithm = Argon2id(
      parallelism: 1, // Web 端多线程支持有限，减少并行度
      memory: 32 * 1024, // 32MB，平衡安全与 Web 加载速度
      iterations: 2, // 减少迭代次数
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
