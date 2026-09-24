// Synthetic interoperability vectors. Never reads a user vault or server.
// Run with the repository's pinned Dart SDK and package configuration.
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import '../lib/features/vault/domain/models/vault_item.dart';

Future<void> main() async {
  const password = ' Legacy fixture password! ';
  final salt = List<int>.generate(16, (i) => i + 1);
  final items = <VaultItem>[
    VaultItem(
      id: 'legacy-password',
      type: VaultItemType.password,
      title: '旧版示例账号',
      username: 'fixture@example.com',
      password: 'Synthetic-only!',
      category: '家庭',
      tags: ['旧版'],
      updatedAt: DateTime.utc(2020, 1, 2),
      passwordHistory: [
        PasswordHistoryEntry(
          password: 'Previous-fixture!',
          changedAt: DateTime.utc(2020, 1, 1),
        ),
      ],
      accounts: [
        AccountEntry(
          id: 'alternate',
          label: '备用账号',
          username: 'other@example.com',
          password: 'Alternate-fixture!',
        ),
      ],
    ),
    VaultItem(
      id: 'legacy-note',
      type: VaultItemType.secureNote,
      title: '旧版笔记',
      username: '',
      note: '合成迁移测试，不含真实资料',
      isPinned: true,
    ),
    VaultItem(
      id: 'legacy-trash',
      type: VaultItemType.password,
      title: '旧版回收站',
      username: '',
      password: 'Deleted-fixture!',
      isDeleted: true,
      deletedAt: DateTime.utc(2020, 1, 3),
    ),
    VaultItem(
      id: 'legacy-code',
      type: VaultItemType.totp,
      title: '旧版验证码',
      username: 'fixture',
      secret: 'JBSWY3DPEHPK3PXP',
      period: 60,
    ),
    VaultItem(
      id: 'legacy-wallet',
      type: VaultItemType.crypto,
      title: '旧版钱包',
      username: '',
      network: 'ETH',
      address: '0x0000000000000000000000000000000000000000',
    ),
  ];
  final clear = jsonEncode({
    'items': items.map((v) => v.toJson()).toList(),
    'sharedVaults': [],
    'sharedMembers': [],
  });
  final argon = Argon2id(
    parallelism: 1,
    memory: 32768,
    iterations: 2,
    hashLength: 32,
  );
  final variants = <String, (SecretKey, Map<String, dynamic>)>{
    'webdav-1.3': (
      await argon.deriveKeyFromPassword(password: password, nonce: salt),
      {
        'version': '1.3.0',
        'salt': base64Encode(salt),
        'iterations': 2,
        'memory': 32768,
        'parallelism': 1,
      },
    ),
    'manual-2.0': (
      await argon.deriveKeyFromPassword(
        password: password.trim(),
        nonce: utf8.encode('SecurePass_Backup_Standard_Salt_2024'),
      ),
      {'version': '2.0.0'},
    ),
    'manual-3.0': (
      SecretKey((await Sha256().hash(utf8.encode(password.trim()))).bytes),
      {'version': '3.0.0', 'scheme': 'sha256_simple'},
    ),
  };
  final folder = Directory('crates/vault-core/tests/fixtures/legacy');
  await folder.create(recursive: true);
  for (final entry in variants.entries) {
    final sealed = await AesGcm.with256bits().encrypt(
      utf8.encode(clear),
      secretKey: entry.value.$1,
      nonce: List<int>.generate(12, (i) => i + 20),
    );
    final envelope = {
      'metadata': {...entry.value.$2, 'encrypted': true},
      'payload': base64Encode(sealed.concatenation()),
    };
    await File(
      '${folder.path}/${entry.key}.json',
    ).writeAsString('${jsonEncode(envelope)}\n');
  }
  await File('${folder.path}/expected.json').writeAsString('$clear\n');
  stdout.writeln(
    'Generated 3 synthetic Dart encryption vectors and their expected records.',
  );
}
