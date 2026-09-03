import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:password/core/security/encryption_service.dart';

void main() {
  late EncryptionService service;

  setUp(() {
    service = EncryptionService();
  });

  group('EncryptionService', () {
    group('deriveKey', () {
      test('produces a 32-byte key', () async {
        final salt = utf8.encode('test-salt-16bytes');
        final key = await service.deriveKey('password123', salt);
        final bytes = await key.extractBytes();
        expect(bytes.length, 32);
      });

      test('same inputs produce same key', () async {
        final salt = utf8.encode('deterministic');
        final k1 = await service.deriveKey('pw', salt);
        final k2 = await service.deriveKey('pw', salt);
        expect(await k1.extractBytes(), await k2.extractBytes());
      });

      test('different passwords produce different keys', () async {
        final salt = utf8.encode('salt');
        final k1 = await service.deriveKey('a', salt);
        final k2 = await service.deriveKey('b', salt);
        expect(await k1.extractBytes(), isNot(await k2.extractBytes()));
      });
    });

    group('deriveKeySimple', () {
      test('produces 32-byte SHA-256 based key', () async {
        final key = await service.deriveKeySimple('hello');
        final bytes = await key.extractBytes();
        expect(bytes.length, 32);
      });
    });

    group('encrypt / decrypt', () {
      test('round-trip with correct key', () async {
        final key = await service.deriveKeySimple('testkey');
        const plaintext = 'Hello, World! 你好世界';
        final encrypted = await service.encrypt(plaintext, key);
        final decrypted = await service.decrypt(encrypted, key);
        expect(decrypted, plaintext);
      });

      test('decrypt with wrong key throws', () async {
        final correctKey = await service.deriveKeySimple('correct');
        final wrongKey = await service.deriveKeySimple('wrong');
        const plaintext = 'secret';
        final encrypted = await service.encrypt(plaintext, correctKey);
        expect(() => service.decrypt(encrypted, wrongKey), throwsA(anything));
      });

      test('decrypt with fallback key succeeds', () async {
        final originalKey = await service.deriveKeySimple('original');
        final fallbackKey = await service.deriveKeySimple('original');
        final wrongPrimaryKey = await service.deriveKeySimple('wrong');
        const plaintext = 'secret data';
        final encrypted = await service.encrypt(plaintext, originalKey);
        final decrypted = await service.decrypt(
          encrypted,
          wrongPrimaryKey,
          fallbacks: [fallbackKey],
        );
        expect(decrypted, plaintext);
      });
    });

    group('ECIES (X25519 + HKDF)', () {
      test('encrypt and decrypt with key pair', () async {
        final keyPair = await service.generateKeyPair();
        final publicKey = await keyPair.extractPublicKey();

        final plainBytes = utf8.encode('ECIES test payload');
        final encrypted = await service.encryptWithPublicKey(
          plainBytes,
          publicKey.bytes,
        );

        expect(encrypted.length, greaterThan(32));

        final decrypted = await service.decryptWithPrivateKey(
          encrypted,
          keyPair,
        );
        expect(utf8.decode(decrypted), 'ECIES test payload');
      });

      test('decrypt with wrong key pair fails', () async {
        await service.generateKeyPair();
        final recipientKp = await service.generateKeyPair();
        final wrongKp = await service.generateKeyPair();

        final recipientPub = await recipientKp.extractPublicKey();
        final encrypted = await service.encryptWithPublicKey(
          utf8.encode('data'),
          recipientPub.bytes,
        );

        expect(
          () => service.decryptWithPrivateKey(encrypted, wrongKp),
          throwsA(anything),
        );
      });
    });

    group('keyPairFromPrivateKey', () {
      test('recovers the same public key', () async {
        final original = await service.generateKeyPair();
        final privBytes = await original.extractPrivateKeyBytes();
        final recovered = await service.keyPairFromPrivateKey(privBytes);
        final origPub = await original.extractPublicKey();
        final recPub = await recovered.extractPublicKey();
        expect(recPub.bytes, origPub.bytes);
      });
    });
  });
}
