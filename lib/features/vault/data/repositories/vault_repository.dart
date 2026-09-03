import 'package:password/core/l10n/l10n.dart';
import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/security/encryption_service.dart';
import '../../domain/models/vault_item.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

class VaultRepository {
  final AppDatabase _db;
  final EncryptionService _encryptionService;
  void Function(String? sharedVaultId)? onItemChanged;

  VaultRepository(this._db, this._encryptionService);

  Future<VaultItemsCompanion> _buildInsertCompanion(
    VaultItem item,
    SecretKey encryptionKey, {
    DateTime? preserveUpdatedAt,
  }) async {
    String? encryptedSecret;
    String? encryptedPassword;
    String? encryptedMnemonic;
    String? encryptedPrivateKey;
    String? encryptedAddress;
    String? encryptedNote;
    String? encryptedPasswordHistory;
    String? encryptedAccounts;
    String? encryptedTags;

    if (item.secret != null) {
      final bytes = await _encryptionService.encrypt(
        item.secret!,
        encryptionKey,
      );
      encryptedSecret = base64.encode(bytes);
    }

    if (item.password != null) {
      final bytes = await _encryptionService.encrypt(
        item.password!,
        encryptionKey,
      );
      encryptedPassword = base64.encode(bytes);
    }

    if (item.mnemonic != null) {
      final bytes = await _encryptionService.encrypt(
        item.mnemonic!,
        encryptionKey,
      );
      encryptedMnemonic = base64.encode(bytes);
    }

    if (item.privateKey != null) {
      final bytes = await _encryptionService.encrypt(
        item.privateKey!,
        encryptionKey,
      );
      encryptedPrivateKey = base64.encode(bytes);
    }

    if (item.address != null) {
      final bytes = await _encryptionService.encrypt(
        item.address!,
        encryptionKey,
      );
      encryptedAddress = base64.encode(bytes);
    }

    if (item.note != null) {
      final bytes = await _encryptionService.encrypt(item.note!, encryptionKey);
      encryptedNote = base64.encode(bytes);
    }

    if (item.passwordHistory != null && item.passwordHistory!.isNotEmpty) {
      final historyJson = jsonEncode(
        item.passwordHistory!.map((e) => e.toJson()).toList(),
      );
      final bytes = await _encryptionService.encrypt(
        historyJson,
        encryptionKey,
      );
      encryptedPasswordHistory = base64.encode(bytes);
    }

    if (item.accounts != null && item.accounts!.isNotEmpty) {
      final accountsJson = jsonEncode(
        item.accounts!.map((e) => e.toJson()).toList(),
      );
      final bytes = await _encryptionService.encrypt(
        accountsJson,
        encryptionKey,
      );
      encryptedAccounts = base64.encode(bytes);
    }

    if (item.tags.isNotEmpty) {
      final tagsJson = jsonEncode(item.tags);
      final bytes = await _encryptionService.encrypt(tagsJson, encryptionKey);
      encryptedTags = base64.encode(bytes);
    }

    final companion = VaultItemsCompanion.insert(
      id: item.id,
      type: item.type.index,
      title: item.title,
      username: item.username,
      secret: Value(encryptedSecret),
      password: Value(encryptedPassword),
      mnemonic: Value(encryptedMnemonic),
      privateKey: Value(encryptedPrivateKey),
      address: Value(encryptedAddress),
      network: Value(item.network),
      period: Value(item.period),
      isFavorite: Value(item.isFavorite),
      url: Value(item.url),
      note: Value(encryptedNote),
      category: Value(item.category),
      email: Value(item.email),
      passwordHistory: Value(encryptedPasswordHistory),
      accounts: Value(encryptedAccounts),
      tags: Value(encryptedTags),
      passwordLastChanged: Value(item.passwordLastChanged),
      passwordDuration: Value(item.passwordDuration),
      isDeleted: Value(item.isDeleted),
      deletedAt: Value(item.deletedAt),
      sharedVaultId: Value(item.sharedVaultId),
      isPinned: Value(item.isPinned),
      colorLabel: Value(item.colorLabel),
    );

    if (preserveUpdatedAt != null) {
      return companion.copyWith(updatedAt: Value(preserveUpdatedAt));
    }
    return companion;
  }

  Future<List<VaultItem>> getAllItems(
    SecretKey masterKey, {
    bool includeDeleted = false,
    List<SecretKey>? fallbacks,
    SimpleKeyPair? userKeyPair,
  }) async {
    final query = _db.select(_db.vaultItems);
    if (!includeDeleted) {
      query.where((t) => t.isDeleted.equals(false));
    }
    final rows = await query.get();

    // 缓存共享库密钥
    final Map<String, SecretKey> sharedKeyCache = {};

    // 如果数据量很大，分批处理以避免阻塞 Web UI 线程
    final List<VaultItem> items = [];
    const int batchSize = 10; // 每批处理 10 条数据

    for (int i = 0; i < rows.length; i += batchSize) {
      final batch = rows.sublist(
        i,
        i + batchSize > rows.length ? rows.length : i + batchSize,
      );

      final decryptedBatch = await Future.wait(
        batch.map((row) async {
          SecretKey encryptionKey = masterKey;

          if (row.sharedVaultId != null && userKeyPair != null) {
            if (sharedKeyCache.containsKey(row.sharedVaultId)) {
              encryptionKey = sharedKeyCache[row.sharedVaultId]!;
            } else {
              final key = await getSharedVaultKey(
                row.sharedVaultId!,
                userKeyPair,
              );
              if (key != null) {
                sharedKeyCache[row.sharedVaultId!] = key;
                encryptionKey = key;
              }
            }
          }

          String? decryptedSecret;
          String? decryptedPassword;
          String? decryptedMnemonic;
          String? decryptedPrivateKey;
          String? decryptedAddress;
          String? decryptedNote;
          String? decryptedPasswordHistory;
          String? decryptedAccounts;
          String? decryptedTags;

          final decryptionTasks = <Future<void>>[];

          // 辅助函数：安全解密，单个字段失败不影响整体
          Future<String?> _safeDecrypt(
            String? encryptedData,
            String fieldName,
          ) async {
            if (encryptedData == null) return null;
            try {
              return await _encryptionService.decrypt(
                base64.decode(encryptedData),
                encryptionKey,
                fallbacks: fallbacks,
              );
            } catch (e) {
              debugPrint(
                '❌ Decryption failed for field $fieldName in item ${row.id}: $e',
              );
              // 如果是备注，则返回原始数据或空，其他敏感字段返回 null 确保安全
              if (fieldName == 'note') return encryptedData;
              return null;
            }
          }

          decryptionTasks.add(
            _safeDecrypt(row.secret, 'secret').then((v) => decryptedSecret = v),
          );
          decryptionTasks.add(
            _safeDecrypt(
              row.password,
              'password',
            ).then((v) => decryptedPassword = v),
          );
          decryptionTasks.add(
            _safeDecrypt(
              row.mnemonic,
              'mnemonic',
            ).then((v) => decryptedMnemonic = v),
          );
          decryptionTasks.add(
            _safeDecrypt(
              row.privateKey,
              'privateKey',
            ).then((v) => decryptedPrivateKey = v),
          );
          decryptionTasks.add(
            _safeDecrypt(
              row.address,
              'address',
            ).then((v) => decryptedAddress = v),
          );
          decryptionTasks.add(
            _safeDecrypt(row.note, 'note').then((v) => decryptedNote = v),
          );
          decryptionTasks.add(
            _safeDecrypt(
              row.passwordHistory,
              'passwordHistory',
            ).then((v) => decryptedPasswordHistory = v),
          );
          decryptionTasks.add(
            _safeDecrypt(
              row.accounts,
              'accounts',
            ).then((v) => decryptedAccounts = v),
          );
          decryptionTasks.add(
            _safeDecrypt(row.tags, 'tags').then((v) => decryptedTags = v),
          );

          if (decryptionTasks.isNotEmpty) {
            await Future.wait(decryptionTasks);
          }

          List<PasswordHistoryEntry>? history;
          if (decryptedPasswordHistory != null) {
            try {
              final List<dynamic> jsonList = jsonDecode(
                decryptedPasswordHistory!,
              );
              history = jsonList
                  .map((e) => PasswordHistoryEntry.fromJson(e))
                  .toList();
            } catch (e) {
              debugPrint('History decode failed: $e');
            }
          }

          List<AccountEntry>? accounts;
          if (decryptedAccounts != null) {
            try {
              final List<dynamic> jsonList = jsonDecode(decryptedAccounts!);
              accounts = jsonList.map((e) => AccountEntry.fromJson(e)).toList();
            } catch (e) {
              debugPrint('Accounts decode failed: $e');
            }
          }

          return VaultItem(
            id: row.id,
            type: VaultItemType.values[row.type],
            title: row.title,
            username: row.username,
            secret: decryptedSecret,
            password: decryptedPassword,
            mnemonic: decryptedMnemonic,
            privateKey: decryptedPrivateKey,
            address: decryptedAddress,
            network: row.network,
            period: row.period,
            isFavorite: row.isFavorite,
            url: row.url,
            note: decryptedNote,
            category: row.category,
            email: row.email,
            passwordHistory: history,
            accounts: accounts,
            passwordLastChanged: row.passwordLastChanged,
            passwordDuration: row.passwordDuration,
            tags: decryptedTags != null
                ? List<String>.from(jsonDecode(decryptedTags!))
                : [],
            isDeleted: row.isDeleted,
            deletedAt: row.deletedAt,
            updatedAt: row.updatedAt,
            sharedVaultId: row.sharedVaultId,
            isPinned: row.isPinned,
            colorLabel: row.colorLabel,
          );
        }),
      );

      items.addAll(decryptedBatch);

      // 给 UI 线程一个喘息的机会
      if (rows.length > batchSize) {
        await Future.delayed(Duration.zero);
      }
    }

    return items;
  }

  Future<void> addItem(
    VaultItem item,
    SecretKey masterKey, {
    SimpleKeyPair? userKeyPair,
  }) async {
    SecretKey encryptionKey = masterKey;
    if (item.sharedVaultId != null && userKeyPair != null) {
      // 检查权限
      final role = await _getMemberRole(item.sharedVaultId!, userKeyPair);
      if (role == null) throw Exception(tr.youAreNotAMemberOfThis);
      if (role == SharedMemberRole.viewer)
        throw Exception(tr.youDoNotHavePermissionToAdd);

      final key = await getSharedVaultKey(item.sharedVaultId!, userKeyPair);
      if (key != null) encryptionKey = key;
    }

    final companion = await _buildInsertCompanion(item, encryptionKey);
    await _db
        .into(_db.vaultItems)
        .insert(companion, mode: InsertMode.insertOrReplace);
    onItemChanged?.call(item.sharedVaultId);
  }

  Future<void> addItems(
    List<VaultItem> items,
    SecretKey masterKey, {
    SimpleKeyPair? userKeyPair,
  }) async {
    for (final item in items) {
      await addItem(item, masterKey, userKeyPair: userKeyPair);
    }
  }

  /// 清空所有数据（用于设置中的“清空数据”功能）
  Future<void> addItemPreservingTimestamp(
    VaultItem item,
    SecretKey masterKey, {
    SimpleKeyPair? userKeyPair,
  }) async {
    SecretKey encryptionKey = masterKey;
    if (item.sharedVaultId != null && userKeyPair != null) {
      final key = await getSharedVaultKey(item.sharedVaultId!, userKeyPair);
      if (key != null) encryptionKey = key;
    }

    final companion = await _buildInsertCompanion(
      item,
      encryptionKey,
      preserveUpdatedAt: item.updatedAt,
    );
    await _db
        .into(_db.vaultItems)
        .insert(companion, mode: InsertMode.insertOrReplace);
    onItemChanged?.call(item.sharedVaultId);
  }

  /// Encrypt all sensitive fields of a VaultItem and return a map of encrypted values.
  Future<Map<String, String?>> _encryptFields(
    VaultItem item,
    SecretKey key,
  ) async {
    Future<String?> enc(String? value) async {
      if (value == null) return null;
      final bytes = await _encryptionService.encrypt(value, key);
      return base64.encode(bytes);
    }

    String? encHistory;
    if (item.passwordHistory != null && item.passwordHistory!.isNotEmpty) {
      encHistory = await enc(
        jsonEncode(item.passwordHistory!.map((e) => e.toJson()).toList()),
      );
    }
    String? encAccounts;
    if (item.accounts != null && item.accounts!.isNotEmpty) {
      encAccounts = await enc(
        jsonEncode(item.accounts!.map((e) => e.toJson()).toList()),
      );
    }
    String? encTags;
    if (item.tags.isNotEmpty) {
      encTags = await enc(jsonEncode(item.tags));
    }

    return {
      'secret': await enc(item.secret),
      'password': await enc(item.password),
      'mnemonic': await enc(item.mnemonic),
      'privateKey': await enc(item.privateKey),
      'address': await enc(item.address),
      'note': await enc(item.note),
      'passwordHistory': encHistory,
      'accounts': encAccounts,
      'tags': encTags,
    };
  }

  /// Build a VaultItemsCompanion for writing from pre-encrypted field map.
  VaultItemsCompanion _buildCompanionFromEncrypted(
    VaultItem item,
    Map<String, String?> enc, {
    DateTime? updatedAt,
    DateTime? passwordLastChanged,
  }) {
    return VaultItemsCompanion(
      title: Value(item.title),
      username: Value(item.username),
      secret: Value(enc['secret']),
      password: Value(enc['password']),
      mnemonic: Value(enc['mnemonic']),
      privateKey: Value(enc['privateKey']),
      address: Value(enc['address']),
      network: Value(item.network),
      period: Value(item.period),
      isFavorite: Value(item.isFavorite),
      url: Value(item.url),
      note: Value(enc['note']),
      category: Value(item.category),
      email: Value(item.email),
      passwordHistory: Value(enc['passwordHistory']),
      accounts: Value(enc['accounts']),
      tags: Value(enc['tags']),
      passwordLastChanged: Value(
        passwordLastChanged ?? item.passwordLastChanged,
      ),
      passwordDuration: Value(item.passwordDuration),
      updatedAt: Value(updatedAt ?? DateTime.now()),
      isDeleted: Value(item.isDeleted),
      deletedAt: Value(item.deletedAt),
      sharedVaultId: Value(item.sharedVaultId),
      isPinned: Value(item.isPinned),
      colorLabel: Value(item.colorLabel),
    );
  }

  Future<void> updateItemFromBackup(
    VaultItem item,
    SecretKey masterKey, {
    SimpleKeyPair? userKeyPair,
  }) async {
    SecretKey encryptionKey = masterKey;
    if (item.sharedVaultId != null && userKeyPair != null) {
      final key = await getSharedVaultKey(item.sharedVaultId!, userKeyPair);
      if (key != null) encryptionKey = key;
    }

    final enc = await _encryptFields(item, encryptionKey);
    final companion = _buildCompanionFromEncrypted(
      item,
      enc,
      updatedAt: item.updatedAt ?? DateTime.now(),
    );

    await (_db.update(
      _db.vaultItems,
    )..where((t) => t.id.equals(item.id))).write(companion);
    onItemChanged?.call(item.sharedVaultId);
  }

  Future<void> deleteAllData() async {
    await _db.transaction(() async {
      await _db.delete(_db.vaultItems).go();
      await _db.delete(_db.sharedMembers).go();
      await _db.delete(_db.sharedVaults).go();
    });
  }

  Future<void> updateItem(
    VaultItem item,
    SecretKey masterKey, {
    SimpleKeyPair? userKeyPair,
  }) async {
    // 1. 获取旧项以检查密码是否更改
    final oldRows = await (_db.select(
      _db.vaultItems,
    )..where((t) => t.id.equals(item.id))).get();
    if (oldRows.isEmpty) return;
    final oldRow = oldRows.first;

    // 确定旧数据的解密密钥
    SecretKey decryptionKey = masterKey;
    if (oldRow.sharedVaultId != null && userKeyPair != null) {
      final key = await getSharedVaultKey(oldRow.sharedVaultId!, userKeyPair);
      if (key != null) decryptionKey = key;
    }

    // 确定新数据的加密密钥
    SecretKey encryptionKey = masterKey;
    if (item.sharedVaultId != null && userKeyPair != null) {
      // 检查权限
      final role = await _getMemberRole(item.sharedVaultId!, userKeyPair);
      if (role == null) throw Exception(tr.youAreNotAMemberOfThis);
      if (role == SharedMemberRole.viewer)
        throw Exception(tr.youDoNotHavePermissionToEdit);

      final key = await getSharedVaultKey(item.sharedVaultId!, userKeyPair);
      if (key != null) encryptionKey = key;
    }

    String? oldDecryptedPassword;
    if (oldRow.password != null) {
      oldDecryptedPassword = await _encryptionService.decrypt(
        base64.decode(oldRow.password!),
        decryptionKey,
      );
    }

    List<PasswordHistoryEntry> currentHistory = [];
    if (oldRow.passwordHistory != null) {
      final decryptedHistory = await _encryptionService.decrypt(
        base64.decode(oldRow.passwordHistory!),
        decryptionKey,
      );
      final List<dynamic> jsonList = jsonDecode(decryptedHistory);
      currentHistory = jsonList
          .map((e) => PasswordHistoryEntry.fromJson(e))
          .toList();
    }

    DateTime? lastChanged = oldRow.passwordLastChanged;

    // 2. 处理主密码历史
    if (item.password != null &&
        item.password != oldDecryptedPassword &&
        oldDecryptedPassword != null) {
      currentHistory.add(
        PasswordHistoryEntry(
          password: oldDecryptedPassword,
          changedAt: lastChanged ?? DateTime.now(),
        ),
      );
      if (currentHistory.length > 10) {
        currentHistory.removeAt(0);
      }
      lastChanged = DateTime.now();
    } else if (item.password != null && oldDecryptedPassword == null) {
      lastChanged = DateTime.now();
    }

    // 3. 处理额外账号密码历史
    List<AccountEntry> updatedAccounts = [];
    if (item.accounts != null) {
      List<AccountEntry> oldAccounts = [];
      if (oldRow.accounts != null) {
        try {
          final decryptedAccounts = await _encryptionService.decrypt(
            base64.decode(oldRow.accounts!),
            decryptionKey,
          );
          final List<dynamic> jsonList = jsonDecode(decryptedAccounts);
          oldAccounts = jsonList.map((e) => AccountEntry.fromJson(e)).toList();
        } catch (e) {
          print('Error decrypting old accounts: $e');
        }
      }

      for (var i = 0; i < item.accounts!.length; i++) {
        var newAcc = item.accounts![i];
        AccountEntry? oldAcc;

        // 1. 优先通过 ID 匹配
        if (newAcc.id.isNotEmpty) {
          try {
            oldAcc = oldAccounts.firstWhere((a) => a.id == newAcc.id);
          } catch (_) {
            oldAcc = null;
          }
        }

        // 2. 如果 ID 匹配失败，尝试通过多种方式模糊匹配（兼容旧数据或 ID 丢失的情况）
        if (oldAcc == null) {
          // 2.1 尝试相同索引的账号（最可能的匹配方式）
          if (i < oldAccounts.length) {
            final possibleMatch = oldAccounts[i];

            // 兼容 label 为空或 null 的情况
            final bool labelMatch =
                (possibleMatch.label == newAcc.label) ||
                (possibleMatch.label == null &&
                    (newAcc.label?.isEmpty ?? true)) ||
                ((possibleMatch.label?.isEmpty ?? true) &&
                    newAcc.label == null);

            // 如果用户名一致，极可能是同一个账号（即使 label 变了）
            if (possibleMatch.username == newAcc.username) {
              oldAcc = possibleMatch;
            } else if (labelMatch && (newAcc.label?.isNotEmpty ?? false)) {
              // 如果用户名变了，但 label 一致且不为空，也可能是同一个账号
              oldAcc = possibleMatch;
            }
          }

          // 2.2 如果索引匹配不成功，在整个旧账号列表中搜索
          if (oldAcc == null) {
            try {
              // 优先匹配用户名和备注都一致的
              oldAcc = oldAccounts.firstWhere((a) {
                final bool labelMatch =
                    (a.label == newAcc.label) ||
                    (a.label == null && (newAcc.label?.isEmpty ?? true)) ||
                    ((a.label?.isEmpty ?? true) && newAcc.label == null);
                return a.username == newAcc.username && labelMatch;
              });
            } catch (_) {
              try {
                // 退而求其次，只匹配用户名一致的
                oldAcc = oldAccounts.firstWhere(
                  (a) => a.username == newAcc.username,
                );
              } catch (_) {
                oldAcc = null;
              }
            }
          }
        }

        if (oldAcc != null && newAcc.password != oldAcc.password) {
          // 密码已更改，更新历史
          List<PasswordHistoryEntry> accHistory = List.from(
            oldAcc.passwordHistory ?? [],
          );
          accHistory.add(
            PasswordHistoryEntry(
              password: oldAcc.password,
              changedAt: oldAcc.passwordLastChanged ?? DateTime.now(),
            ),
          );
          if (accHistory.length > 10) accHistory.removeAt(0);

          updatedAccounts.add(
            AccountEntry(
              id: newAcc.id,
              username: newAcc.username,
              password: newAcc.password,
              label: newAcc.label,
              passwordHistory: accHistory,
              passwordLastChanged: DateTime.now(),
            ),
          );
        } else if (oldAcc != null) {
          // 密码未更改，保留旧的历史和时间
          updatedAccounts.add(
            AccountEntry(
              id: newAcc.id,
              username: newAcc.username,
              password: newAcc.password,
              label: newAcc.label,
              passwordHistory: oldAcc.passwordHistory,
              passwordLastChanged: oldAcc.passwordLastChanged,
            ),
          );
        } else {
          // 找不到对应的旧账号，视为新账号或匹配完全失败
          // 如果 UI 传过来的账号已经有历史（虽然不常见），则尝试保留
          updatedAccounts.add(
            AccountEntry(
              id: newAcc.id,
              username: newAcc.username,
              password: newAcc.password,
              label: newAcc.label,
              passwordHistory: newAcc.passwordHistory,
              passwordLastChanged: newAcc.passwordLastChanged ?? DateTime.now(),
            ),
          );
        }
      }
    } else if (oldRow.accounts != null) {
      // 如果新项中没有 accounts，但旧项中有，则保留旧的（防止意外抹除）
    }

    // Build item with merged history/accounts for encryption
    // 必须带上 isPinned / colorLabel 等元数据，否则会用 VaultItem 默认值写入并覆盖数据库
    final itemToEncrypt = VaultItem(
      id: item.id,
      type: item.type,
      title: item.title,
      username: item.username,
      secret: item.secret,
      password: item.password,
      mnemonic: item.mnemonic,
      privateKey: item.privateKey,
      address: item.address,
      network: item.network,
      period: item.period,
      isFavorite: item.isFavorite,
      url: item.url,
      note: item.note,
      category: item.category,
      email: item.email,
      passwordHistory: currentHistory.isNotEmpty ? currentHistory : null,
      accounts: updatedAccounts.isNotEmpty ? updatedAccounts : null,
      tags: item.tags,
      sharedVaultId: item.sharedVaultId,
      passwordLastChanged: lastChanged,
      passwordDuration: item.passwordDuration,
      isDeleted: item.isDeleted,
      deletedAt: item.deletedAt,
      isPinned: item.isPinned,
      colorLabel: item.colorLabel,
    );

    final enc = await _encryptFields(itemToEncrypt, encryptionKey);
    final companion = _buildCompanionFromEncrypted(
      itemToEncrypt,
      enc,
      passwordLastChanged: lastChanged,
    );

    await (_db.update(
      _db.vaultItems,
    )..where((t) => t.id.equals(item.id))).write(companion);
    onItemChanged?.call(item.sharedVaultId);
  }

  Future<void> deleteItem(String id, {String? sharedVaultId}) async {
    await (_db.update(_db.vaultItems)..where((t) => t.id.equals(id))).write(
      const VaultItemsCompanion(isDeleted: Value(true)),
    );
    onItemChanged?.call(sharedVaultId);
  }

  Future<void> permanentlyDeleteItem(String id, {String? sharedVaultId}) async {
    await (_db.delete(_db.vaultItems)..where((t) => t.id.equals(id))).go();
    onItemChanged?.call(sharedVaultId);
  }

  Future<void> softDeleteItem(String id, {SimpleKeyPair? userKeyPair}) async {
    final item = await (_db.select(
      _db.vaultItems,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (item != null && item.sharedVaultId != null && userKeyPair != null) {
      final role = await _getMemberRole(item.sharedVaultId!, userKeyPair);
      if (role == null) throw Exception(tr.youAreNotAMemberOfThis);
      if (role == SharedMemberRole.viewer)
        throw Exception(tr.youDoNotHavePermissionToDelete);
    }

    await (_db.update(_db.vaultItems)..where((t) => t.id.equals(id))).write(
      VaultItemsCompanion(
        isDeleted: const Value(true),
        deletedAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> restoreItem(String id, {SimpleKeyPair? userKeyPair}) async {
    final item = await (_db.select(
      _db.vaultItems,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (item != null && item.sharedVaultId != null && userKeyPair != null) {
      final role = await _getMemberRole(item.sharedVaultId!, userKeyPair);
      if (role == null) throw Exception(tr.youAreNotAMemberOfThis);
      if (role == SharedMemberRole.viewer)
        throw Exception(tr.youDoNotHavePermissionToRestore);
    }

    await (_db.update(_db.vaultItems)..where((t) => t.id.equals(id))).write(
      VaultItemsCompanion(
        isDeleted: const Value(false),
        deletedAt: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> createSharedVault({
    required String name,
    required SimpleKeyPair ownerKeyPair,
    required String ownerName,
  }) async {
    final vaultId = DateTime.now().millisecondsSinceEpoch.toString();

    // 1. 生成共享库的对称密钥 (VaultKey)
    final _secureRandom = Random.secure();
    final vaultKeyBytes = List<int>.generate(
      32,
      (i) => _secureRandom.nextInt(256),
    );
    final vaultKeyBase64 = base64.encode(vaultKeyBytes);

    // 2. 用所有者的公钥加密 VaultKey
    final ownerPublicKey = await ownerKeyPair.extractPublicKey();
    final encryptedVaultKeyForOwner = await _encryptionService
        .encryptWithPublicKey(
          utf8.encode(vaultKeyBase64),
          ownerPublicKey.bytes,
        );

    await _db.transaction(() async {
      // 3. 插入共享库
      await _db
          .into(_db.sharedVaults)
          .insert(
            SharedVaultsCompanion.insert(
              id: vaultId,
              name: name,
              encryptedVaultKey: base64.encode(encryptedVaultKeyForOwner),
            ),
          );

      // 4. 将所有者添加为成员
      await _db
          .into(_db.sharedMembers)
          .insert(
            SharedMembersCompanion.insert(
              id: "${vaultId}_owner",
              vaultId: vaultId,
              userPublicKey: base64.encode(ownerPublicKey.bytes),
              encryptedVaultKey: base64.encode(encryptedVaultKeyForOwner),
              role: SharedMemberRole.owner.index,
              name: Value(ownerName),
            ),
          );
    });
  }

  Future<void> addMemberToSharedVault({
    required String vaultId,
    required String memberPublicKeyBase64,
    required String memberName,
    required SharedMemberRole role,
    required SimpleKeyPair currentUserKeyPair,
  }) async {
    // 1. 获取当前用户持有的 VaultKey
    // 允许管理员或所有者添加成员
    final currentUserPubKey = await currentUserKeyPair.extractPublicKey();
    final currentUserMember =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(vaultId))
              ..where(
                (t) => t.userPublicKey.equals(
                  base64.encode(currentUserPubKey.bytes),
                ),
              ))
            .getSingleOrNull();

    if (currentUserMember == null) throw Exception(tr.memberRecordNotFound);
    if (SharedMemberRole.values[currentUserMember.role] ==
        SharedMemberRole.viewer) {
      throw Exception(tr.viewersCannotAddMembers);
    }

    final encryptedVaultKeyForMe = base64.decode(
      currentUserMember.encryptedVaultKey,
    );
    final decryptedVaultKeyBytes = await _encryptionService
        .decryptWithPrivateKey(encryptedVaultKeyForMe, currentUserKeyPair);
    final vaultKeyBase64 = utf8.decode(decryptedVaultKeyBytes);

    // 2. 用新成员的公钥加密 VaultKey
    final memberPublicKeyBytes = base64.decode(memberPublicKeyBase64);
    final encryptedVaultKeyForMember = await _encryptionService
        .encryptWithPublicKey(
          utf8.encode(vaultKeyBase64),
          memberPublicKeyBytes,
        );

    // 3. 插入成员记录
    await _db
        .into(_db.sharedMembers)
        .insert(
          SharedMembersCompanion.insert(
            id: "${vaultId}_member_${DateTime.now().millisecondsSinceEpoch}",
            vaultId: vaultId,
            userPublicKey: memberPublicKeyBase64,
            encryptedVaultKey: base64.encode(encryptedVaultKeyForMember),
            role: role.index,
            name: Value(memberName),
          ),
        );
  }

  Future<void> removeMemberFromSharedVault({
    required String vaultId,
    required String memberId,
    required SimpleKeyPair currentUserKeyPair,
  }) async {
    final currentUserPublicKey = base64.encode(
      (await currentUserKeyPair.extractPublicKey()).bytes,
    );
    final currentUserMember =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(vaultId))
              ..where((t) => t.userPublicKey.equals(currentUserPublicKey)))
            .getSingleOrNull();

    if (currentUserMember == null ||
        SharedMemberRole.values[currentUserMember.role] !=
            SharedMemberRole.owner) {
      throw Exception(tr.onlyTheOwnerCanRemoveMembers);
    }

    final targetMember = await (_db.select(
      _db.sharedMembers,
    )..where((t) => t.id.equals(memberId))).getSingleOrNull();
    if (targetMember == null) throw Exception(tr.memberNotFound);
    if (SharedMemberRole.values[targetMember.role] == SharedMemberRole.owner) {
      throw Exception(tr.theOwnerCannotBeRemoved);
    }

    await (_db.delete(
      _db.sharedMembers,
    )..where((t) => t.id.equals(memberId))).go();
  }

  Future<void> updateMemberRole({
    required String vaultId,
    required String memberId,
    required SharedMemberRole newRole,
    required SimpleKeyPair currentUserKeyPair,
  }) async {
    final currentUserPublicKey = base64.encode(
      (await currentUserKeyPair.extractPublicKey()).bytes,
    );
    final currentUserMember =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(vaultId))
              ..where((t) => t.userPublicKey.equals(currentUserPublicKey)))
            .getSingleOrNull();

    if (currentUserMember == null ||
        SharedMemberRole.values[currentUserMember.role] !=
            SharedMemberRole.owner) {
      throw Exception(tr.onlyTheOwnerCanChangePermissions);
    }

    final targetMember = await (_db.select(
      _db.sharedMembers,
    )..where((t) => t.id.equals(memberId))).getSingleOrNull();
    if (targetMember == null) throw Exception(tr.memberNotFound);
    if (SharedMemberRole.values[targetMember.role] == SharedMemberRole.owner) {
      throw Exception(tr.theOwnerSPermissionsCannotBeChanged);
    }

    await (_db.update(_db.sharedMembers)..where((t) => t.id.equals(memberId)))
        .write(SharedMembersCompanion(role: Value(newRole.index)));
  }

  Future<void> deleteSharedVault({
    required String vaultId,
    required SimpleKeyPair currentUserKeyPair,
  }) async {
    final currentUserPublicKey = base64.encode(
      (await currentUserKeyPair.extractPublicKey()).bytes,
    );
    final currentUserMember =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(vaultId))
              ..where((t) => t.userPublicKey.equals(currentUserPublicKey)))
            .getSingleOrNull();

    if (currentUserMember == null ||
        SharedMemberRole.values[currentUserMember.role] !=
            SharedMemberRole.owner) {
      throw Exception(tr.onlyTheOwnerCanDeleteThisShared);
    }

    await _db.transaction(() async {
      await (_db.delete(
        _db.sharedVaults,
      )..where((t) => t.id.equals(vaultId))).go();
      await (_db.delete(
        _db.sharedMembers,
      )..where((t) => t.vaultId.equals(vaultId))).go();
      // 将所有属于该库的项设为未归属
      await (_db.update(_db.vaultItems)
            ..where((t) => t.sharedVaultId.equals(vaultId)))
          .write(const VaultItemsCompanion(sharedVaultId: Value(null)));
    });
  }

  Future<void> rotateSharedVaultKey({
    required String vaultId,
    required SimpleKeyPair currentUserKeyPair,
  }) async {
    // 1. 验证权限（仅所有者可以轮转密钥）
    final currentUserPubKey = await currentUserKeyPair.extractPublicKey();
    final currentUserMember =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(vaultId))
              ..where(
                (t) => t.userPublicKey.equals(
                  base64.encode(currentUserPubKey.bytes),
                ),
              ))
            .getSingleOrNull();

    if (currentUserMember == null ||
        SharedMemberRole.values[currentUserMember.role] !=
            SharedMemberRole.owner) {
      throw Exception(tr.onlyTheOwnerCanRotateTheKey);
    }

    // 2. 获取旧密钥以解密现有项
    final oldEncryptedKey = base64.decode(currentUserMember.encryptedVaultKey);
    final oldKeyBytes = await _encryptionService.decryptWithPrivateKey(
      oldEncryptedKey,
      currentUserKeyPair,
    );
    final oldKeyBase64 = utf8.decode(oldKeyBytes);
    final oldSecretKey = SecretKey(base64.decode(oldKeyBase64));

    // 3. 生成新密钥
    final _secureRandom = Random.secure();
    final newVaultKeyBytes = List<int>.generate(
      32,
      (i) => _secureRandom.nextInt(256),
    );
    final newVaultKeyBase64 = base64.encode(newVaultKeyBytes);
    final newSecretKey = SecretKey(newVaultKeyBytes);

    // 4. 获取所有成员并为他们重新加密新密钥
    final members = await (_db.select(
      _db.sharedMembers,
    )..where((t) => t.vaultId.equals(vaultId))).get();
    final memberUpdates = <SharedMembersCompanion>[];
    for (final member in members) {
      final encryptedNewKey = await _encryptionService.encryptWithPublicKey(
        utf8.encode(newVaultKeyBase64),
        base64.decode(member.userPublicKey),
      );
      memberUpdates.add(
        SharedMembersCompanion(
          id: Value(member.id),
          encryptedVaultKey: Value(base64.encode(encryptedNewKey)),
        ),
      );
    }

    // 5. 获取所有属于该库的项
    final rows = await (_db.select(
      _db.vaultItems,
    )..where((t) => t.sharedVaultId.equals(vaultId))).get();
    final itemUpdates = <VaultItemsCompanion>[];

    for (final row in rows) {
      // 解密现有数据
      final decryptedItem = await _decryptVaultItemRow(row, oldSecretKey);
      // 用新密钥重新加密
      final companion = await _buildInsertCompanion(
        decryptedItem,
        newSecretKey,
      );
      itemUpdates.add(companion.copyWith(id: Value(row.id)));
    }

    // 6. 执行事务更新
    await _db.transaction(() async {
      // 更新成员的密钥
      for (final update in memberUpdates) {
        await (_db.update(
          _db.sharedMembers,
        )..where((t) => t.id.equals(update.id.value))).write(update);
      }

      // 更新库的密钥（存储的是所有者的版本）
      final encryptedNewKeyForOwner = await _encryptionService
          .encryptWithPublicKey(
            utf8.encode(newVaultKeyBase64),
            currentUserPubKey.bytes,
          );
      await (_db.update(
        _db.sharedVaults,
      )..where((t) => t.id.equals(vaultId))).write(
        SharedVaultsCompanion(
          encryptedVaultKey: Value(base64.encode(encryptedNewKeyForOwner)),
        ),
      );

      // 更新所有项
      for (final update in itemUpdates) {
        await (_db.update(
          _db.vaultItems,
        )..where((t) => t.id.equals(update.id.value))).write(update);
      }
    });
  }

  Future<VaultItem> _decryptVaultItemRow(
    VaultItemEntity row,
    SecretKey encryptionKey,
  ) async {
    String? decryptedSecret;
    String? decryptedPassword;
    String? decryptedMnemonic;
    String? decryptedPrivateKey;
    String? decryptedAddress;
    String? decryptedNote;
    String? decryptedPasswordHistory;
    String? decryptedAccounts;
    String? decryptedTags;

    final decryptionTasks = <Future<void>>[];

    if (row.secret != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.secret!), encryptionKey)
            .then((v) => decryptedSecret = v),
      );
    }

    if (row.password != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.password!), encryptionKey)
            .then((v) => decryptedPassword = v),
      );
    }

    if (row.mnemonic != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.mnemonic!), encryptionKey)
            .then((v) => decryptedMnemonic = v),
      );
    }

    if (row.privateKey != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.privateKey!), encryptionKey)
            .then((v) => decryptedPrivateKey = v),
      );
    }

    if (row.address != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.address!), encryptionKey)
            .then((v) => decryptedAddress = v),
      );
    }

    if (row.note != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.note!), encryptionKey)
            .then((v) => decryptedNote = v)
            .catchError((_) {
              decryptedNote = row.note;
              return decryptedNote ?? '';
            }),
      );
    }

    if (row.passwordHistory != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.passwordHistory!), encryptionKey)
            .then((v) => decryptedPasswordHistory = v),
      );
    }

    if (row.accounts != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.accounts!), encryptionKey)
            .then((v) => decryptedAccounts = v),
      );
    }

    if (row.tags != null) {
      decryptionTasks.add(
        _encryptionService
            .decrypt(base64.decode(row.tags!), encryptionKey)
            .then((v) => decryptedTags = v),
      );
    }

    if (decryptionTasks.isNotEmpty) {
      await Future.wait(decryptionTasks);
    }

    List<PasswordHistoryEntry>? history;
    if (decryptedPasswordHistory != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(decryptedPasswordHistory!);
        history = jsonList
            .map((e) => PasswordHistoryEntry.fromJson(e))
            .toList();
      } catch (_) {}
    }

    List<AccountEntry>? accounts;
    if (decryptedAccounts != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(decryptedAccounts!);
        accounts = jsonList.map((e) => AccountEntry.fromJson(e)).toList();
      } catch (_) {}
    }

    return VaultItem(
      id: row.id,
      type: VaultItemType.values[row.type],
      title: row.title,
      username: row.username,
      secret: decryptedSecret,
      password: decryptedPassword,
      mnemonic: decryptedMnemonic,
      privateKey: decryptedPrivateKey,
      address: decryptedAddress,
      network: row.network,
      period: row.period,
      isFavorite: row.isFavorite,
      url: row.url,
      note: decryptedNote,
      category: row.category,
      email: row.email,
      passwordHistory: history,
      accounts: accounts,
      passwordLastChanged: row.passwordLastChanged,
      passwordDuration: row.passwordDuration,
      tags: decryptedTags != null
          ? List<String>.from(jsonDecode(decryptedTags!))
          : [],
      isDeleted: row.isDeleted,
      deletedAt: row.deletedAt,
      updatedAt: row.updatedAt,
      sharedVaultId: row.sharedVaultId,
      isPinned: row.isPinned,
      colorLabel: row.colorLabel,
    );
  }

  Future<List<SharedVault>> getSharedVaults(SimpleKeyPair userKeyPair) async {
    final rows = await _db.select(_db.sharedVaults).get();
    return rows
        .map(
          (row) => SharedVault(
            id: row.id,
            name: row.name,
            encryptedVaultKey: row.encryptedVaultKey,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            isDiscoverable: row.isDiscoverable,
          ),
        )
        .toList();
  }

  Future<List<SharedMember>> getVaultMembers(String vaultId) async {
    final rows = await (_db.select(
      _db.sharedMembers,
    )..where((t) => t.vaultId.equals(vaultId))).get();
    return rows
        .map(
          (row) => SharedMember(
            id: row.id,
            vaultId: row.vaultId,
            userPublicKey: row.userPublicKey,
            encryptedVaultKey: row.encryptedVaultKey,
            role: SharedMemberRole.values[row.role],
            name: row.name,
          ),
        )
        .toList();
  }

  Future<List<SharedMember>> getAllSharedMembers() async {
    final rows = await _db.select(_db.sharedMembers).get();
    return rows
        .map(
          (row) => SharedMember(
            id: row.id,
            vaultId: row.vaultId,
            userPublicKey: row.userPublicKey,
            encryptedVaultKey: row.encryptedVaultKey,
            role: SharedMemberRole.values[row.role],
            name: row.name,
          ),
        )
        .toList();
  }

  Future<void> addSharedVaults(List<SharedVault> vaults) async {
    if (vaults.isEmpty) return;
    await _db.batch((batch) {
      batch.insertAll(
        _db.sharedVaults,
        vaults.map(
          (v) => SharedVaultsCompanion.insert(
            id: v.id,
            name: v.name,
            encryptedVaultKey: v.encryptedVaultKey,
            createdAt: Value(v.createdAt),
            updatedAt: Value(v.updatedAt),
            isDiscoverable: Value(v.isDiscoverable),
          ),
        ),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  Future<Map<String, int>> mergeSharedVaults(
    List<SharedVault> backupVaults,
  ) async {
    if (backupVaults.isEmpty) return {'added': 0, 'updated': 0, 'skipped': 0};

    final existingRows = await _db.select(_db.sharedVaults).get();
    final existingIndex = <String, DateTime>{};
    for (final row in existingRows) {
      existingIndex[row.id] = row.updatedAt;
    }

    int added = 0, updated = 0, skipped = 0;

    for (final vault in backupVaults) {
      final localUpdatedAt = existingIndex[vault.id];
      if (localUpdatedAt == null) {
        await _db
            .into(_db.sharedVaults)
            .insert(
              SharedVaultsCompanion.insert(
                id: vault.id,
                name: vault.name,
                encryptedVaultKey: vault.encryptedVaultKey,
                createdAt: Value(vault.createdAt),
                updatedAt: Value(vault.updatedAt),
                isDiscoverable: Value(vault.isDiscoverable),
              ),
              mode: InsertMode.insertOrReplace,
            );
        added++;
      } else if (vault.updatedAt.isAfter(localUpdatedAt)) {
        await (_db.update(
          _db.sharedVaults,
        )..where((t) => t.id.equals(vault.id))).write(
          SharedVaultsCompanion(
            name: Value(vault.name),
            encryptedVaultKey: Value(vault.encryptedVaultKey),
            updatedAt: Value(vault.updatedAt),
            isDiscoverable: Value(vault.isDiscoverable),
          ),
        );
        updated++;
      } else {
        skipped++;
      }
    }

    return {'added': added, 'updated': updated, 'skipped': skipped};
  }

  Future<void> updateSharedVaultDiscoverable(
    String vaultId,
    bool isDiscoverable,
  ) async {
    await (_db.update(_db.sharedVaults)..where((t) => t.id.equals(vaultId)))
        .write(SharedVaultsCompanion(isDiscoverable: Value(isDiscoverable)));
  }

  Future<void> addSharedMembers(List<SharedMember> members) async {
    if (members.isEmpty) return;
    await _db.batch((batch) {
      batch.insertAll(
        _db.sharedMembers,
        members.map(
          (m) => SharedMembersCompanion.insert(
            id: m.id,
            vaultId: m.vaultId,
            userPublicKey: m.userPublicKey,
            encryptedVaultKey: m.encryptedVaultKey,
            role: m.role.index,
            name: Value(m.name),
          ),
        ),
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  Future<SecretKey?> getSharedVaultKey(
    String sharedVaultId,
    SimpleKeyPair userKeyPair,
  ) async {
    final publicKey = await userKeyPair.extractPublicKey();
    final publicKeyBase64 = base64.encode(publicKey.bytes);

    final member =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(sharedVaultId))
              ..where((t) => t.userPublicKey.equals(publicKeyBase64)))
            .getSingleOrNull();

    if (member == null) return null;

    final encryptedVaultKey = base64.decode(member.encryptedVaultKey);
    final decryptedKeyBytes = await _encryptionService.decryptWithPrivateKey(
      encryptedVaultKey,
      userKeyPair,
    );
    final decryptedKeyBase64 = utf8.decode(decryptedKeyBytes);
    return SecretKey(base64.decode(decryptedKeyBase64));
  }

  Future<SharedMemberRole?> _getMemberRole(
    String sharedVaultId,
    SimpleKeyPair userKeyPair,
  ) async {
    final publicKey = await userKeyPair.extractPublicKey();
    final publicKeyBase64 = base64.encode(publicKey.bytes);

    final member =
        await (_db.select(_db.sharedMembers)
              ..where((t) => t.vaultId.equals(sharedVaultId))
              ..where((t) => t.userPublicKey.equals(publicKeyBase64)))
            .getSingleOrNull();

    if (member == null) return null;
    return SharedMemberRole.values[member.role];
  }
}
