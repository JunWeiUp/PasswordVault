import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'connection/connection.dart' as impl;

part 'app_database.g.dart';

@DataClassName('VaultItemEntity')
class VaultItems extends Table {
  TextColumn get id => text()();
  IntColumn get type => integer()(); // 0 for password, 1 for totp
  TextColumn get title => text()();
  TextColumn get username => text()();
  TextColumn get secret => text().nullable()();
  TextColumn get password => text().nullable()();
  TextColumn get mnemonic => text().nullable()();
  TextColumn get privateKey => text().nullable()();
  TextColumn get address => text().nullable()();
  TextColumn get network => text().nullable()();
  IntColumn get period => integer().withDefault(const Constant(30))();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  TextColumn get url => text().nullable()();
  TextColumn get note => text().nullable()();
  TextColumn get category => text().nullable()();
  TextColumn get email => text().nullable()();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get passwordHistory => text().nullable()(); // Encrypted JSON
  DateTimeColumn get passwordLastChanged => dateTime().nullable()();
  IntColumn get passwordDuration => integer().nullable()(); // Days
  TextColumn get accounts => text().nullable()(); // Encrypted JSON
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get tags =>
      text().nullable()(); // Comma separated or JSON array of tags
  TextColumn get sharedVaultId =>
      text().nullable().references(SharedVaults, #id)();
  BoolColumn get isPinned => boolean().withDefault(const Constant(false))();
  TextColumn get colorLabel => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SharedVaultEntity')
class SharedVaults extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get encryptedVaultKey => text()(); // 对当前用户加密后的 VaultKey (Base64)
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get isDiscoverable =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SharedMemberEntity')
class SharedMembers extends Table {
  TextColumn get id => text()();
  TextColumn get vaultId =>
      text().references(SharedVaults, #id, onDelete: KeyAction.cascade)();
  TextColumn get userPublicKey => text()(); // 成员的公钥 (Base64)
  TextColumn get encryptedVaultKey => text()(); // 对该成员加密后的 VaultKey (Base64)
  IntColumn get role => integer()(); // 0: Viewer, 1: Editor, 2: Owner
  TextColumn get name => text().nullable()(); // 成员备注名

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [VaultItems, SharedVaults, SharedMembers])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(impl.connect());

  @override
  int get schemaVersion => 12;

  /// Safely add a column; logs a warning if it already exists instead of silently swallowing.
  Future<void> _safeAddColumn(
    Migrator m,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    try {
      await m.addColumn(table, column);
    } catch (e) {
      debugPrint(
        'DB migration: column ${column.name} likely already exists – $e',
      );
    }
  }

  Future<void> _safeCreateTable(Migrator m, TableInfo table) async {
    try {
      await m.createTable(table);
    } catch (e) {
      debugPrint(
        'DB migration: table ${table.actualTableName} likely already exists – $e',
      );
    }
  }

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      debugPrint('DB migration: upgrading from v$from to v$to');
      if (from < 2) {
        await m.addColumn(vaultItems, vaultItems.mnemonic);
        await m.addColumn(vaultItems, vaultItems.address);
      }
      if (from < 3) {
        await m.addColumn(vaultItems, vaultItems.network);
      }
      if (from < 4) {
        await m.addColumn(vaultItems, vaultItems.privateKey);
      }
      if (from < 5) {
        await _safeAddColumn(m, vaultItems, vaultItems.privateKey);
      }
      if (from < 6) {
        await _safeAddColumn(m, vaultItems, vaultItems.passwordHistory);
        await _safeAddColumn(m, vaultItems, vaultItems.passwordLastChanged);
        await _safeAddColumn(m, vaultItems, vaultItems.passwordDuration);
      }
      if (from < 7) {
        await _safeAddColumn(m, vaultItems, vaultItems.accounts);
      }
      if (from < 8) {
        await _safeAddColumn(m, vaultItems, vaultItems.isDeleted);
        await _safeAddColumn(m, vaultItems, vaultItems.deletedAt);
      }
      if (from < 9) {
        await _safeAddColumn(m, vaultItems, vaultItems.tags);
      }
      if (from < 10) {
        await _safeCreateTable(m, sharedVaults);
        await _safeCreateTable(m, sharedMembers);
        await _safeAddColumn(m, vaultItems, vaultItems.sharedVaultId);
      }
      if (from < 11) {
        await _safeAddColumn(m, sharedVaults, sharedVaults.isDiscoverable);
      }
      if (from < 12) {
        await _safeAddColumn(m, vaultItems, vaultItems.isPinned);
        await _safeAddColumn(m, vaultItems, vaultItems.colorLabel);
      }
      debugPrint('DB migration: upgrade complete');
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');

      if (details.versionBefore != null && details.versionNow >= 10) {
        final m = createMigrator();
        await _safeAddColumn(m, vaultItems, vaultItems.sharedVaultId);
        await _safeCreateTable(m, sharedVaults);
        await _safeCreateTable(m, sharedMembers);
        await _safeAddColumn(m, vaultItems, vaultItems.passwordHistory);
        await _safeAddColumn(m, vaultItems, vaultItems.passwordLastChanged);
        await _safeAddColumn(m, vaultItems, vaultItems.passwordDuration);
        await _safeAddColumn(m, vaultItems, vaultItems.accounts);
        await _safeAddColumn(m, vaultItems, vaultItems.isDeleted);
        await _safeAddColumn(m, vaultItems, vaultItems.deletedAt);
        await _safeAddColumn(m, vaultItems, vaultItems.tags);
        await _safeAddColumn(m, vaultItems, vaultItems.isPinned);
        await _safeAddColumn(m, vaultItems, vaultItems.colorLabel);
      }
    },
  );
}
