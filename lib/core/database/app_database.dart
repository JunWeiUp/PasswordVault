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

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [VaultItems])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(impl.connect());

  @override
  int get schemaVersion => 5;

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
        // 尝试添加 privateKey，如果版本是从 3 升级来的
        await m.addColumn(vaultItems, vaultItems.privateKey);
      }
      if (from < 5) {
        // 如果是从版本 4 升级来的，但之前的 privateKey 添加失败了（虽然这种情况少见，但为了修复用户的错误）
        // Drift 的 addColumn 如果列已存在会抛出异常，所以我们包裹在 try-catch 中，或者直接信任 version 5 的强制升级
        try {
          await m.addColumn(vaultItems, vaultItems.privateKey);
        } catch (e) {
          // 列可能已经存在，忽略错误
        }
      }
    },
  );
}
