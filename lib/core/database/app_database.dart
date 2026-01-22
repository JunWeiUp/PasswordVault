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

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [VaultItems])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(impl.connect());

  @override
  int get schemaVersion => 8;

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
        await m.addColumn(vaultItems, vaultItems.passwordHistory);
        await m.addColumn(vaultItems, vaultItems.passwordLastChanged);
        await m.addColumn(vaultItems, vaultItems.passwordDuration);
      }
      if (from < 7) {
        await m.addColumn(vaultItems, vaultItems.accounts);
      }
      if (from < 8) {
        await m.addColumn(vaultItems, (vaultItems as dynamic).isDeleted);
        await m.addColumn(vaultItems, (vaultItems as dynamic).deletedAt);
      }
    },
    beforeOpen: (details) async {
      // 开启外键约束
      await customStatement('PRAGMA foreign_keys = ON');
      
      // 防御性检查：确保新列确实存在 (针对开发环境迁移失败的情况)
      if (details.versionBefore != null && details.versionNow >= 8) {
        final m = createMigrator();
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
          await m.addColumn(vaultItems, (vaultItems as dynamic).isDeleted);
        } catch (e) { /* Ignore if exists */ }
        try {
          await m.addColumn(vaultItems, (vaultItems as dynamic).deletedAt);
        } catch (e) { /* Ignore if exists */ }
      }
    },
  );
}
