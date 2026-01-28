import 'package:drift/drift.dart';
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
  TextColumn get tags => text().nullable()(); // Comma separated or JSON array of tags
  TextColumn get sharedVaultId => text().nullable().references(SharedVaults, #id)();

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
  BoolColumn get isDiscoverable => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SharedMemberEntity')
class SharedMembers extends Table {
  TextColumn get id => text()();
  TextColumn get vaultId => text().references(SharedVaults, #id, onDelete: KeyAction.cascade)();
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
  int get schemaVersion => 11;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
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
        try {
          await m.addColumn(vaultItems, vaultItems.privateKey);
        } catch (e) {
          // Ignore if column exists
        }
      }
      if (from < 6) {
        try {
          await m.addColumn(vaultItems, vaultItems.passwordHistory);
          await m.addColumn(vaultItems, vaultItems.passwordLastChanged);
          await m.addColumn(vaultItems, vaultItems.passwordDuration);
        } catch (_) {}
      }
      if (from < 7) {
        try {
          await m.addColumn(vaultItems, vaultItems.accounts);
        } catch (_) {}
      }
      if (from < 8) {
        try {
          await m.addColumn(vaultItems, vaultItems.isDeleted);
          await m.addColumn(vaultItems, vaultItems.deletedAt);
        } catch (_) {}
      }
      if (from < 9) {
        try {
          await m.addColumn(vaultItems, vaultItems.tags);
        } catch (_) {}
      }
      if (from < 10) {
        try {
          await m.createTable(sharedVaults);
          await m.createTable(sharedMembers);
          await m.addColumn(vaultItems, vaultItems.sharedVaultId);
        } catch (_) {}
      }
      if (from < 11) {
        try {
          await m.addColumn(sharedVaults, sharedVaults.isDiscoverable);
        } catch (_) {}
      }
    },
    beforeOpen: (details) async {
      // 开启外键约束
      await customStatement('PRAGMA foreign_keys = ON');
      
      // 防御性检查：确保新列确实存在 (针对开发环境迁移失败的情况)
      if (details.versionBefore != null && details.versionNow >= 10) {
        final m = createMigrator();
        try {
          await m.addColumn(vaultItems, vaultItems.sharedVaultId);
        } catch (e) { /* Ignore if exists */ }
        
        // 尝试创建表（如果不存在）
        try {
          await m.createTable(sharedVaults);
        } catch (e) { /* Ignore */ }
        try {
          await m.createTable(sharedMembers);
        } catch (e) { /* Ignore */ }

        try {
          await m.addColumn(vaultItems, vaultItems.passwordHistory);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, vaultItems.passwordLastChanged);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, vaultItems.passwordDuration);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, vaultItems.accounts);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, vaultItems.isDeleted);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, vaultItems.deletedAt);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, vaultItems.tags);
        } catch (e) { /* Ignore if exists */ }
      }
    },
  );
}
