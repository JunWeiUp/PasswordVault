import 'package:password/core/l10n/l10n.dart';
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
    return algorithm.deriveKeyFromPassword(password: password, nonce: salt);
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

  // 解密：支持多个候选密钥，防止因密钥派生方案变更导致解密失败
  Future<String> decrypt(
    List<int> encryptedData,
    SecretKey key, {
    List<SecretKey>? fallbacks,
  }) async {
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
            final clearText = await _cipher.decrypt(
              secretBox,
              secretKey: fallbackKey,
            );
            return utf8.decode(clearText);
          } catch (_) {
            continue;
          }
        }
      }

      // 如果所有密钥都失败，且错误包含 MAC 或 authentication，则抛出特定异常
      if (e.toString().contains('MAC') ||
          e.toString().contains('authentication')) {
        throw Exception(
          tr.decryptionFailedAuthenticationMismatchCheckTheMaster,
        );
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
      publicKey: await X25519()
          .newKeyPairFromSeed(privateKeyBytes)
          .then((k) => k.extractPublicKey()),
      type: KeyPairType.x25519,
    );
  }

  /// Derive a symmetric AES key from an X25519 shared secret via HKDF-SHA256.
  Future<SecretKey> _deriveFromSharedSecret(SecretKey sharedSecret) async {
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    return await hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode('PasswordVault-ECIES-v1'),
    );
  }

  // ECIES-style encryption using X25519 key exchange + HKDF + AES-GCM.
  // Returns: [EphemeralPublicKey (32 bytes)] + [Nonce + Ciphertext + MAC]
  Future<List<int>> encryptWithPublicKey(
    List<int> data,
    List<int> recipientPublicKeyBytes,
  ) async {
    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();

    final recipientPublicKey = SimplePublicKey(
      recipientPublicKeyBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: recipientPublicKey,
    );

    final derivedKey = await _deriveFromSharedSecret(sharedSecret);
    final secretBox = await _cipher.encrypt(data, secretKey: derivedKey);

    return [...ephemeralPublicKey.bytes, ...secretBox.concatenation()];
  }

  // ECIES-style decryption using X25519 key exchange + HKDF + AES-GCM.
  Future<List<int>> decryptWithPrivateKey(
    List<int> encryptedData,
    SimpleKeyPair keyPair,
  ) async {
    if (encryptedData.length < 32) throw Exception('Invalid encrypted data');

    final x25519 = X25519();
    final ephemeralPublicKeyBytes = encryptedData.sublist(0, 32);
    final secretBoxBytes = encryptedData.sublist(32);

    final ephemeralPublicKey = SimplePublicKey(
      ephemeralPublicKeyBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: ephemeralPublicKey,
    );

    final derivedKey = await _deriveFromSharedSecret(sharedSecret);

    final secretBox = SecretBox.fromConcatenation(
      secretBoxBytes,
      nonceLength: _cipher.nonceLength,
      macLength: _cipher.macAlgorithm.macLength,
    );

    return await _cipher.decrypt(secretBox, secretKey: derivedKey);
  }
}
