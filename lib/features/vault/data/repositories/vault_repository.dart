import 'dart:convert';
import 'package:drift/drift.dart';
import '../../../../core/database/app_database.dart' hide VaultItem;
import '../../../../core/security/encryption_service.dart';
import '../../domain/models/vault_item.dart';
import 'package:cryptography/cryptography.dart';

class VaultRepository {
  final AppDatabase _db;
  final EncryptionService _encryptionService;

  VaultRepository(this._db, this._encryptionService);

  Future<VaultItemsCompanion> _buildInsertCompanion(
    VaultItem item,
    SecretKey masterKey,
  ) async {
    String? encryptedSecret;
    String? encryptedPassword;
    String? encryptedMnemonic;
    String? encryptedPrivateKey;
    String? encryptedAddress;
    String? encryptedNote;
    String? encryptedPasswordHistory;
    String? encryptedAccounts;

    if (item.secret != null) {
      final bytes = await _encryptionService.encrypt(item.secret!, masterKey);
      encryptedSecret = base64.encode(bytes);
    }

    if (item.password != null) {
      final bytes = await _encryptionService.encrypt(item.password!, masterKey);
      encryptedPassword = base64.encode(bytes);
    }

    if (item.mnemonic != null) {
      final bytes = await _encryptionService.encrypt(item.mnemonic!, masterKey);
      encryptedMnemonic = base64.encode(bytes);
    }

    if (item.privateKey != null) {
      final bytes = await _encryptionService.encrypt(item.privateKey!, masterKey);
      encryptedPrivateKey = base64.encode(bytes);
    }

    if (item.address != null) {
      final bytes = await _encryptionService.encrypt(item.address!, masterKey);
      encryptedAddress = base64.encode(bytes);
    }

    if (item.note != null) {
      final bytes = await _encryptionService.encrypt(item.note!, masterKey);
      encryptedNote = base64.encode(bytes);
    }

    if (item.passwordHistory != null && item.passwordHistory!.isNotEmpty) {
      final historyJson = jsonEncode(item.passwordHistory!.map((e) => e.toJson()).toList());
      final bytes = await _encryptionService.encrypt(historyJson, masterKey);
      encryptedPasswordHistory = base64.encode(bytes);
    }

    if (item.accounts != null && item.accounts!.isNotEmpty) {
      final accountsJson = jsonEncode(item.accounts!.map((e) => e.toJson()).toList());
      final bytes = await _encryptionService.encrypt(accountsJson, masterKey);
      encryptedAccounts = base64.encode(bytes);
    }

    return VaultItemsCompanion.insert(
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
      passwordLastChanged: Value(item.passwordLastChanged),
      passwordDuration: Value(item.passwordDuration),
    );
  }

  Future<List<VaultItem>> getAllItems(SecretKey masterKey) async {
    final rows = await _db.select(_db.vaultItems).get();
    
    // 如果数据量很大，分批处理以避免阻塞 Web UI 线程
    final List<VaultItem> items = [];
    const int batchSize = 10; // 每批处理 10 条数据
    
    for (int i = 0; i < rows.length; i += batchSize) {
      final batch = rows.sublist(i, i + batchSize > rows.length ? rows.length : i + batchSize);
      
      final decryptedBatch = await Future.wait(batch.map((row) async {
        String? decryptedSecret;
        String? decryptedPassword;
        String? decryptedMnemonic;
        String? decryptedPrivateKey;
        String? decryptedAddress;
        String? decryptedNote;
        String? decryptedPasswordHistory;
        String? decryptedAccounts;

        final decryptionTasks = <Future<void>>[];

        if (row.secret != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.secret!), masterKey)
              .then((v) => decryptedSecret = v));
        }

        if (row.password != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.password!), masterKey)
              .then((v) => decryptedPassword = v));
        }

        if (row.mnemonic != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.mnemonic!), masterKey)
              .then((v) => decryptedMnemonic = v));
        }

        if (row.privateKey != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.privateKey!), masterKey)
              .then((v) => decryptedPrivateKey = v));
        }

        if (row.address != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.address!), masterKey)
              .then((v) => decryptedAddress = v));
        }

        if (row.note != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.note!), masterKey)
              .then((v) => decryptedNote = v)
              .catchError((_) => decryptedNote = row.note));
        }

        if (row.passwordHistory != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.passwordHistory!), masterKey)
              .then((v) => decryptedPasswordHistory = v));
        }

        if (row.accounts != null) {
          decryptionTasks.add(_encryptionService.decrypt(base64.decode(row.accounts!), masterKey)
              .then((v) => decryptedAccounts = v));
        }

        if (decryptionTasks.isNotEmpty) {
          await Future.wait(decryptionTasks);
        }

        List<PasswordHistoryEntry>? history;
        if (decryptedPasswordHistory != null) {
          try {
            final List<dynamic> jsonList = jsonDecode(decryptedPasswordHistory!);
            history = jsonList.map((e) => PasswordHistoryEntry.fromJson(e)).toList();
          } catch (e) {
            print('History decode failed: $e');
          }
        }

        List<AccountEntry>? accounts;
        if (decryptedAccounts != null) {
          try {
            final List<dynamic> jsonList = jsonDecode(decryptedAccounts!);
            accounts = jsonList.map((e) => AccountEntry.fromJson(e)).toList();
          } catch (e) {
            print('Accounts decode failed: $e');
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
        );
      }));
      
      items.addAll(decryptedBatch);
      
      // 给 UI 线程一个喘息的机会
      if (rows.length > batchSize) {
        await Future.delayed(Duration.zero);
      }
    }
    
    return items;
  }

  Future<void> addItem(VaultItem item, SecretKey masterKey) async {
    final companion = await _buildInsertCompanion(item, masterKey);
    await _db.into(_db.vaultItems).insert(
      companion,
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<void> addItems(List<VaultItem> items, SecretKey masterKey) async {
    if (items.isEmpty) return;
    final companions = <VaultItemsCompanion>[];
    for (final item in items) {
      companions.add(await _buildInsertCompanion(item, masterKey));
    }
    await _db.batch((batch) {
      batch.insertAll(
        _db.vaultItems,
        companions,
        mode: InsertMode.insertOrReplace,
      );
    });
  }

  Future<void> updateItem(VaultItem item, SecretKey masterKey) async {
    // 1. 获取旧项以检查密码是否更改
    final oldRows = await (_db.select(_db.vaultItems)..where((t) => t.id.equals(item.id))).get();
    if (oldRows.isEmpty) return;
    final oldRow = oldRows.first;

    String? oldDecryptedPassword;
    if (oldRow.password != null) {
      oldDecryptedPassword = await _encryptionService.decrypt(
        base64.decode(oldRow.password!), 
        masterKey
      );
    }

    List<PasswordHistoryEntry> currentHistory = [];
    if (oldRow.passwordHistory != null) {
      final decryptedHistory = await _encryptionService.decrypt(
        base64.decode(oldRow.passwordHistory!), 
        masterKey
      );
      final List<dynamic> jsonList = jsonDecode(decryptedHistory);
      currentHistory = jsonList.map((e) => PasswordHistoryEntry.fromJson(e)).toList();
    }

    DateTime? lastChanged = oldRow.passwordLastChanged;
    
    // 2. 处理主密码历史
    if (item.password != null && item.password != oldDecryptedPassword && oldDecryptedPassword != null) {
      currentHistory.add(PasswordHistoryEntry(
        password: oldDecryptedPassword,
        changedAt: lastChanged ?? DateTime.now(),
      ));
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
            masterKey
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
            final bool labelMatch = (possibleMatch.label == newAcc.label) || 
                                   (possibleMatch.label == null && (newAcc.label?.isEmpty ?? true)) ||
                                   ((possibleMatch.label?.isEmpty ?? true) && newAcc.label == null);
            
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
                final bool labelMatch = (a.label == newAcc.label) || 
                                       (a.label == null && (newAcc.label?.isEmpty ?? true)) ||
                                       ((a.label?.isEmpty ?? true) && newAcc.label == null);
                return a.username == newAcc.username && labelMatch;
              });
            } catch (_) {
              try {
                // 退而求其次，只匹配用户名一致的
                oldAcc = oldAccounts.firstWhere((a) => a.username == newAcc.username);
              } catch (_) {
                oldAcc = null;
              }
            }
          }
        }
        
        if (oldAcc != null && newAcc.password != oldAcc.password) {
          // 密码已更改，更新历史
          List<PasswordHistoryEntry> accHistory = List.from(oldAcc.passwordHistory ?? []);
          accHistory.add(PasswordHistoryEntry(
            password: oldAcc.password,
            changedAt: oldAcc.passwordLastChanged ?? DateTime.now(),
          ));
          if (accHistory.length > 10) accHistory.removeAt(0);
          
          updatedAccounts.add(AccountEntry(
            id: newAcc.id,
            username: newAcc.username,
            password: newAcc.password,
            label: newAcc.label,
            passwordHistory: accHistory,
            passwordLastChanged: DateTime.now(),
          ));
        } else if (oldAcc != null) {
          // 密码未更改，保留旧的历史和时间
          updatedAccounts.add(AccountEntry(
            id: newAcc.id,
            username: newAcc.username,
            password: newAcc.password,
            label: newAcc.label,
            passwordHistory: oldAcc.passwordHistory,
            passwordLastChanged: oldAcc.passwordLastChanged,
          ));
        } else {
          // 找不到对应的旧账号，视为新账号或匹配完全失败
          // 如果 UI 传过来的账号已经有历史（虽然不常见），则尝试保留
          updatedAccounts.add(AccountEntry(
            id: newAcc.id,
            username: newAcc.username,
            password: newAcc.password,
            label: newAcc.label,
            passwordHistory: newAcc.passwordHistory,
            passwordLastChanged: newAcc.passwordLastChanged ?? DateTime.now(),
          ));
        }
      }
    } else if (oldRow.accounts != null) {
      // 如果新项中没有 accounts，但旧项中有，则保留旧的（防止意外抹除）
      // 这里可以根据业务逻辑决定是保留还是删除，通常如果是 full model 更新则应该删除
      // 但为了安全起见，我们只有在明确 item.accounts 是空列表时才删除
    }

    String? encryptedSecret;
    String? encryptedPassword;
    String? encryptedMnemonic;
    String? encryptedPrivateKey;
    String? encryptedAddress;
    String? encryptedNote;
    String? encryptedPasswordHistory;
    String? encryptedAccounts;

    if (item.secret != null) {
      final bytes = await _encryptionService.encrypt(item.secret!, masterKey);
      encryptedSecret = base64.encode(bytes);
    }

    if (item.password != null) {
      final bytes = await _encryptionService.encrypt(item.password!, masterKey);
      encryptedPassword = base64.encode(bytes);
    }

    if (item.mnemonic != null) {
      final bytes = await _encryptionService.encrypt(item.mnemonic!, masterKey);
      encryptedMnemonic = base64.encode(bytes);
    }

    if (item.privateKey != null) {
      final bytes = await _encryptionService.encrypt(item.privateKey!, masterKey);
      encryptedPrivateKey = base64.encode(bytes);
    }

    if (item.address != null) {
      final bytes = await _encryptionService.encrypt(item.address!, masterKey);
      encryptedAddress = base64.encode(bytes);
    }

    if (item.note != null) {
      final bytes = await _encryptionService.encrypt(item.note!, masterKey);
      encryptedNote = base64.encode(bytes);
    }

    if (currentHistory.isNotEmpty) {
      final historyJson = jsonEncode(currentHistory.map((e) => e.toJson()).toList());
      final bytes = await _encryptionService.encrypt(historyJson, masterKey);
      encryptedPasswordHistory = base64.encode(bytes);
    }

    if (updatedAccounts.isNotEmpty) {
      final accountsJson = jsonEncode(updatedAccounts.map((e) => e.toJson()).toList());
      final bytes = await _encryptionService.encrypt(accountsJson, masterKey);
      encryptedAccounts = base64.encode(bytes);
    }

    await (_db.update(_db.vaultItems)..where((t) => t.id.equals(item.id))).write(
      VaultItemsCompanion(
        title: Value(item.title),
        username: Value(item.username),
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
        passwordLastChanged: Value(lastChanged),
        passwordDuration: Value(item.passwordDuration),
      ),
    );
  }

  Future<void> deleteItem(String id) async {
    await (_db.delete(_db.vaultItems)..where((t) => t.id.equals(id))).go();
  }
}
