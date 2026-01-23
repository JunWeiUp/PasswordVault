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

<<<<<<< Updated upstream
  // 解密：支持多个候选密钥，防止因密钥派生方案变更导致解密失败
  Future<String> decrypt(List<int> encryptedData, SecretKey key, {List<SecretKey>? fallbacks}) async {
=======
  // 加密
  Future<String> decrypt(List<int> encryptedData, SecretKey key) async {
>>>>>>> Stashed changes
    final secretBox = SecretBox.fromConcatenation(
      encryptedData,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );

    try {
      final clearText = await _cipher.decrypt(secretBox, secretKey: key);
      return utf8.decode(clearText);
    } catch (e) {
      if (fallbacks != null && fallbacks.isNotEmpty) {
        for (final fallbackKey in fallbacks) {
          try {
            final clearText = await _cipher.decrypt(secretBox, secretKey: fallbackKey);
            return utf8.decode(clearText);
          } catch (_) {
            continue;
          }
        }
      }
      
      // 如果所有密钥都失败，且错误包含 MAC 或 authentication，则抛出特定异常
      if (e.toString().contains('MAC') || e.toString().contains('authentication')) {
        throw Exception('解密失败：认证失败 (MAC mismatch)，可能是主密码错误或数据格式不兼容');
      }
      rethrow;
    }
  }

  // --- 非对称加密 (X25519) 支持 ---

  // 生成用户密钥对
  Future<SimpleKeyPair> generateKeyPair() async {
    return await X25519().newKeyPair();
  }

  // 从私钥字节恢复密钥对
  Future<SimpleKeyPair> keyPairFromPrivateKey(List<int> privateKeyBytes) async {
    return SimpleKeyPairData(
      privateKeyBytes,
      publicKey: await X25519().newKeyPairFromSeed(privateKeyBytes).then((k) => k.extractPublicKey()),
      type: KeyPairType.x25519,
    );
  }

  // 使用 X25519 密钥交换加密对称密钥 (ECIES 风格)
  // 返回: [EphemeralPublicKey (32 bytes)] + [Nonce (12 bytes)] + [EncryptedData]
  Future<List<int>> encryptWithPublicKey(List<int> data, List<int> recipientPublicKeyBytes) async {
    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    
    final recipientPublicKey = SimplePublicKey(recipientPublicKeyBytes, type: KeyPairType.x25519);
    
    // 密钥交换得到共享密钥
    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublicKey,
    );
    
    // 使用共享密钥加密数据
    final secretBox = await _cipher.encrypt(data, secretKey: sharedSecret);
    
    // 拼接结果: 临时公钥 + SecretBox 拼接结果
    return [...ephemeralPublicKey.bytes, ...secretBox.concatenation()];
  }

  // 使用私钥解密
  Future<List<int>> decryptWithPrivateKey(List<int> encryptedData, SimpleKeyPair keyPair) async {
    if (encryptedData.length < 32) throw Exception('Invalid encrypted data');
    
    final x25519 = X25519();
    final ephemeralPublicKeyBytes = encryptedData.sublist(0, 32);
    final secretBoxBytes = encryptedData.sublist(32);
    
    final ephemeralPublicKey = SimplePublicKey(ephemeralPublicKeyBytes, type: KeyPairType.x25519);
    
    // 密钥交换得到共享密钥
    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: ephemeralPublicKey,
    );
    
    // 解密
    final secretBox = SecretBox.fromConcatenation(
      secretBoxBytes,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );
    
    return await _cipher.decrypt(secretBox, secretKey: sharedSecret);
  }
}
