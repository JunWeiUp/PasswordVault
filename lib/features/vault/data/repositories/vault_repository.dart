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

    await _db.into(_db.vaultItems).insert(VaultItemsCompanion.insert(
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
    ));
  }

  Future<void> updateItem(VaultItem item, SecretKey masterKey) async {
    String? encryptedSecret;
    String? encryptedPassword;
    String? encryptedMnemonic;
    String? encryptedPrivateKey;
    String? encryptedAddress;
    String? encryptedNote;

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
      ),
    );
  }

  Future<void> deleteItem(String id) async {
    await (_db.delete(_db.vaultItems)..where((t) => t.id.equals(id))).go();
  }
}
