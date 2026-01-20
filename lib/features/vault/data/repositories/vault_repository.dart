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

  Future<List<VaultItem>> getAllItems(SecretKey masterKey) async {
    final rows = await _db.select(_db.vaultItems).get();
    List<VaultItem> items = [];
    
    for (var row in rows) {
      String? decryptedSecret;
      String? decryptedPassword;
      String? decryptedMnemonic;
      String? decryptedPrivateKey;
      String? decryptedAddress;
      String? decryptedNote;
      String? decryptedPasswordHistory;

      if (row.secret != null) {
        decryptedSecret = await _encryptionService.decrypt(
          base64.decode(row.secret!), 
          masterKey
        );
      }

      if (row.password != null) {
        decryptedPassword = await _encryptionService.decrypt(
          base64.decode(row.password!), 
          masterKey
        );
      }

      if (row.mnemonic != null) {
        decryptedMnemonic = await _encryptionService.decrypt(
          base64.decode(row.mnemonic!), 
          masterKey
        );
      }

      if (row.privateKey != null) {
        decryptedPrivateKey = await _encryptionService.decrypt(
          base64.decode(row.privateKey!), 
          masterKey
        );
      }

      if (row.address != null) {
        decryptedAddress = await _encryptionService.decrypt(
          base64.decode(row.address!), 
          masterKey
        );
      }

      if (row.note != null) {
        try {
          decryptedNote = await _encryptionService.decrypt(
            base64.decode(row.note!), 
            masterKey
          );
        } catch (e) {
          // Fallback if note was not encrypted
          decryptedNote = row.note;
        }
      }

      if (row.passwordHistory != null) {
        decryptedPasswordHistory = await _encryptionService.decrypt(
          base64.decode(row.passwordHistory!), 
          masterKey
        );
      }

      List<PasswordHistoryEntry>? history;
      if (decryptedPasswordHistory != null) {
        final List<dynamic> jsonList = jsonDecode(decryptedPasswordHistory);
        history = jsonList.map((e) => PasswordHistoryEntry.fromJson(e)).toList();
      }

      items.add(VaultItem(
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
        passwordLastChanged: row.passwordLastChanged,
        passwordDuration: row.passwordDuration,
      ));
    }
    return items;
  }

  Future<void> addItem(VaultItem item, SecretKey masterKey) async {
    String? encryptedSecret;
    String? encryptedPassword;
    String? encryptedMnemonic;
    String? encryptedPrivateKey;
    String? encryptedAddress;
    String? encryptedNote;
    String? encryptedPasswordHistory;

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

    await _db.into(_db.vaultItems).insert(
      VaultItemsCompanion.insert(
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
        passwordLastChanged: Value(item.passwordLastChanged),
        passwordDuration: Value(item.passwordDuration),
      ),
      mode: InsertMode.insertOrReplace,
    );
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
    
    // 2. 如果密码更改了，将其添加到历史记录并更新最后更改时间
    if (item.password != null && item.password != oldDecryptedPassword && oldDecryptedPassword != null) {
      currentHistory.add(PasswordHistoryEntry(
        password: oldDecryptedPassword,
        changedAt: lastChanged ?? DateTime.now(),
      ));
      // 保持历史记录不要太长，比如保留最近 10 个
      if (currentHistory.length > 10) {
        currentHistory.removeAt(0);
      }
      lastChanged = DateTime.now();
    } else if (item.password != null && oldDecryptedPassword == null) {
      // 第一次设置密码
      lastChanged = DateTime.now();
    }

    String? encryptedSecret;
    String? encryptedPassword;
    String? encryptedMnemonic;
    String? encryptedPrivateKey;
    String? encryptedAddress;
    String? encryptedNote;
    String? encryptedPasswordHistory;

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
        passwordLastChanged: Value(lastChanged),
        passwordDuration: Value(item.passwordDuration),
      ),
    );
  }

  Future<void> deleteItem(String id) async {
    await (_db.delete(_db.vaultItems)..where((t) => t.id.equals(id))).go();
  }
}
