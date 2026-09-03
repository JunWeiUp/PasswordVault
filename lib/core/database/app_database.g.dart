// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SharedVaultsTable extends SharedVaults
    with TableInfo<$SharedVaultsTable, SharedVaultEntity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SharedVaultsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _encryptedVaultKeyMeta = const VerificationMeta(
    'encryptedVaultKey',
  );
  @override
  late final GeneratedColumn<String> encryptedVaultKey =
      GeneratedColumn<String>(
        'encrypted_vault_key',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _isDiscoverableMeta = const VerificationMeta(
    'isDiscoverable',
  );
  @override
  late final GeneratedColumn<bool> isDiscoverable = GeneratedColumn<bool>(
    'is_discoverable',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_discoverable" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    encryptedVaultKey,
    createdAt,
    updatedAt,
    isDiscoverable,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'shared_vaults';
  @override
  VerificationContext validateIntegrity(
    Insertable<SharedVaultEntity> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('encrypted_vault_key')) {
      context.handle(
        _encryptedVaultKeyMeta,
        encryptedVaultKey.isAcceptableOrUnknown(
          data['encrypted_vault_key']!,
          _encryptedVaultKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_encryptedVaultKeyMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('is_discoverable')) {
      context.handle(
        _isDiscoverableMeta,
        isDiscoverable.isAcceptableOrUnknown(
          data['is_discoverable']!,
          _isDiscoverableMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SharedVaultEntity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SharedVaultEntity(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      encryptedVaultKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}encrypted_vault_key'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      isDiscoverable: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_discoverable'],
      )!,
    );
  }

  @override
  $SharedVaultsTable createAlias(String alias) {
    return $SharedVaultsTable(attachedDatabase, alias);
  }
}

class SharedVaultEntity extends DataClass
    implements Insertable<SharedVaultEntity> {
  final String id;
  final String name;
  final String encryptedVaultKey;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDiscoverable;
  const SharedVaultEntity({
    required this.id,
    required this.name,
    required this.encryptedVaultKey,
    required this.createdAt,
    required this.updatedAt,
    required this.isDiscoverable,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['encrypted_vault_key'] = Variable<String>(encryptedVaultKey);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['is_discoverable'] = Variable<bool>(isDiscoverable);
    return map;
  }

  SharedVaultsCompanion toCompanion(bool nullToAbsent) {
    return SharedVaultsCompanion(
      id: Value(id),
      name: Value(name),
      encryptedVaultKey: Value(encryptedVaultKey),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      isDiscoverable: Value(isDiscoverable),
    );
  }

  factory SharedVaultEntity.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SharedVaultEntity(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      encryptedVaultKey: serializer.fromJson<String>(json['encryptedVaultKey']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      isDiscoverable: serializer.fromJson<bool>(json['isDiscoverable']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'encryptedVaultKey': serializer.toJson<String>(encryptedVaultKey),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'isDiscoverable': serializer.toJson<bool>(isDiscoverable),
    };
  }

  SharedVaultEntity copyWith({
    String? id,
    String? name,
    String? encryptedVaultKey,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDiscoverable,
  }) => SharedVaultEntity(
    id: id ?? this.id,
    name: name ?? this.name,
    encryptedVaultKey: encryptedVaultKey ?? this.encryptedVaultKey,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    isDiscoverable: isDiscoverable ?? this.isDiscoverable,
  );
  SharedVaultEntity copyWithCompanion(SharedVaultsCompanion data) {
    return SharedVaultEntity(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      encryptedVaultKey: data.encryptedVaultKey.present
          ? data.encryptedVaultKey.value
          : this.encryptedVaultKey,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      isDiscoverable: data.isDiscoverable.present
          ? data.isDiscoverable.value
          : this.isDiscoverable,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SharedVaultEntity(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('encryptedVaultKey: $encryptedVaultKey, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('isDiscoverable: $isDiscoverable')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    encryptedVaultKey,
    createdAt,
    updatedAt,
    isDiscoverable,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SharedVaultEntity &&
          other.id == this.id &&
          other.name == this.name &&
          other.encryptedVaultKey == this.encryptedVaultKey &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.isDiscoverable == this.isDiscoverable);
}

class SharedVaultsCompanion extends UpdateCompanion<SharedVaultEntity> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> encryptedVaultKey;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<bool> isDiscoverable;
  final Value<int> rowid;
  const SharedVaultsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.encryptedVaultKey = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.isDiscoverable = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SharedVaultsCompanion.insert({
    required String id,
    required String name,
    required String encryptedVaultKey,
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.isDiscoverable = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       encryptedVaultKey = Value(encryptedVaultKey);
  static Insertable<SharedVaultEntity> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? encryptedVaultKey,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<bool>? isDiscoverable,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (encryptedVaultKey != null) 'encrypted_vault_key': encryptedVaultKey,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (isDiscoverable != null) 'is_discoverable': isDiscoverable,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SharedVaultsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? encryptedVaultKey,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<bool>? isDiscoverable,
    Value<int>? rowid,
  }) {
    return SharedVaultsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      encryptedVaultKey: encryptedVaultKey ?? this.encryptedVaultKey,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDiscoverable: isDiscoverable ?? this.isDiscoverable,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (encryptedVaultKey.present) {
      map['encrypted_vault_key'] = Variable<String>(encryptedVaultKey.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (isDiscoverable.present) {
      map['is_discoverable'] = Variable<bool>(isDiscoverable.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SharedVaultsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('encryptedVaultKey: $encryptedVaultKey, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('isDiscoverable: $isDiscoverable, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $VaultItemsTable extends VaultItems
    with TableInfo<$VaultItemsTable, VaultItemEntity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _usernameMeta = const VerificationMeta(
    'username',
  );
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
    'username',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _secretMeta = const VerificationMeta('secret');
  @override
  late final GeneratedColumn<String> secret = GeneratedColumn<String>(
    'secret',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _passwordMeta = const VerificationMeta(
    'password',
  );
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
    'password',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mnemonicMeta = const VerificationMeta(
    'mnemonic',
  );
  @override
  late final GeneratedColumn<String> mnemonic = GeneratedColumn<String>(
    'mnemonic',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _privateKeyMeta = const VerificationMeta(
    'privateKey',
  );
  @override
  late final GeneratedColumn<String> privateKey = GeneratedColumn<String>(
    'private_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _addressMeta = const VerificationMeta(
    'address',
  );
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
    'address',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _networkMeta = const VerificationMeta(
    'network',
  );
  @override
  late final GeneratedColumn<String> network = GeneratedColumn<String>(
    'network',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _periodMeta = const VerificationMeta('period');
  @override
  late final GeneratedColumn<int> period = GeneratedColumn<int>(
    'period',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(30),
  );
  static const VerificationMeta _isFavoriteMeta = const VerificationMeta(
    'isFavorite',
  );
  @override
  late final GeneratedColumn<bool> isFavorite = GeneratedColumn<bool>(
    'is_favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_favorite" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
    'url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _categoryMeta = const VerificationMeta(
    'category',
  );
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
    'category',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
    'email',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _passwordHistoryMeta = const VerificationMeta(
    'passwordHistory',
  );
  @override
  late final GeneratedColumn<String> passwordHistory = GeneratedColumn<String>(
    'password_history',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _passwordLastChangedMeta =
      const VerificationMeta('passwordLastChanged');
  @override
  late final GeneratedColumn<DateTime> passwordLastChanged =
      GeneratedColumn<DateTime>(
        'password_last_changed',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _passwordDurationMeta = const VerificationMeta(
    'passwordDuration',
  );
  @override
  late final GeneratedColumn<int> passwordDuration = GeneratedColumn<int>(
    'password_duration',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _accountsMeta = const VerificationMeta(
    'accounts',
  );
  @override
  late final GeneratedColumn<String> accounts = GeneratedColumn<String>(
    'accounts',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _isDeletedMeta = const VerificationMeta(
    'isDeleted',
  );
  @override
  late final GeneratedColumn<bool> isDeleted = GeneratedColumn<bool>(
    'is_deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_deleted" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tagsMeta = const VerificationMeta('tags');
  @override
  late final GeneratedColumn<String> tags = GeneratedColumn<String>(
    'tags',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sharedVaultIdMeta = const VerificationMeta(
    'sharedVaultId',
  );
  @override
  late final GeneratedColumn<String> sharedVaultId = GeneratedColumn<String>(
    'shared_vault_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES shared_vaults (id)',
    ),
  );
  static const VerificationMeta _isPinnedMeta = const VerificationMeta(
    'isPinned',
  );
  @override
  late final GeneratedColumn<bool> isPinned = GeneratedColumn<bool>(
    'is_pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _colorLabelMeta = const VerificationMeta(
    'colorLabel',
  );
  @override
  late final GeneratedColumn<String> colorLabel = GeneratedColumn<String>(
    'color_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    type,
    title,
    username,
    secret,
    password,
    mnemonic,
    privateKey,
    address,
    network,
    period,
    isFavorite,
    url,
    note,
    category,
    email,
    updatedAt,
    passwordHistory,
    passwordLastChanged,
    passwordDuration,
    accounts,
    isDeleted,
    deletedAt,
    tags,
    sharedVaultId,
    isPinned,
    colorLabel,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<VaultItemEntity> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('username')) {
      context.handle(
        _usernameMeta,
        username.isAcceptableOrUnknown(data['username']!, _usernameMeta),
      );
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('secret')) {
      context.handle(
        _secretMeta,
        secret.isAcceptableOrUnknown(data['secret']!, _secretMeta),
      );
    }
    if (data.containsKey('password')) {
      context.handle(
        _passwordMeta,
        password.isAcceptableOrUnknown(data['password']!, _passwordMeta),
      );
    }
    if (data.containsKey('mnemonic')) {
      context.handle(
        _mnemonicMeta,
        mnemonic.isAcceptableOrUnknown(data['mnemonic']!, _mnemonicMeta),
      );
    }
    if (data.containsKey('private_key')) {
      context.handle(
        _privateKeyMeta,
        privateKey.isAcceptableOrUnknown(data['private_key']!, _privateKeyMeta),
      );
    }
    if (data.containsKey('address')) {
      context.handle(
        _addressMeta,
        address.isAcceptableOrUnknown(data['address']!, _addressMeta),
      );
    }
    if (data.containsKey('network')) {
      context.handle(
        _networkMeta,
        network.isAcceptableOrUnknown(data['network']!, _networkMeta),
      );
    }
    if (data.containsKey('period')) {
      context.handle(
        _periodMeta,
        period.isAcceptableOrUnknown(data['period']!, _periodMeta),
      );
    }
    if (data.containsKey('is_favorite')) {
      context.handle(
        _isFavoriteMeta,
        isFavorite.isAcceptableOrUnknown(data['is_favorite']!, _isFavoriteMeta),
      );
    }
    if (data.containsKey('url')) {
      context.handle(
        _urlMeta,
        url.isAcceptableOrUnknown(data['url']!, _urlMeta),
      );
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('category')) {
      context.handle(
        _categoryMeta,
        category.isAcceptableOrUnknown(data['category']!, _categoryMeta),
      );
    }
    if (data.containsKey('email')) {
      context.handle(
        _emailMeta,
        email.isAcceptableOrUnknown(data['email']!, _emailMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    }
    if (data.containsKey('password_history')) {
      context.handle(
        _passwordHistoryMeta,
        passwordHistory.isAcceptableOrUnknown(
          data['password_history']!,
          _passwordHistoryMeta,
        ),
      );
    }
    if (data.containsKey('password_last_changed')) {
      context.handle(
        _passwordLastChangedMeta,
        passwordLastChanged.isAcceptableOrUnknown(
          data['password_last_changed']!,
          _passwordLastChangedMeta,
        ),
      );
    }
    if (data.containsKey('password_duration')) {
      context.handle(
        _passwordDurationMeta,
        passwordDuration.isAcceptableOrUnknown(
          data['password_duration']!,
          _passwordDurationMeta,
        ),
      );
    }
    if (data.containsKey('accounts')) {
      context.handle(
        _accountsMeta,
        accounts.isAcceptableOrUnknown(data['accounts']!, _accountsMeta),
      );
    }
    if (data.containsKey('is_deleted')) {
      context.handle(
        _isDeletedMeta,
        isDeleted.isAcceptableOrUnknown(data['is_deleted']!, _isDeletedMeta),
      );
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    if (data.containsKey('tags')) {
      context.handle(
        _tagsMeta,
        tags.isAcceptableOrUnknown(data['tags']!, _tagsMeta),
      );
    }
    if (data.containsKey('shared_vault_id')) {
      context.handle(
        _sharedVaultIdMeta,
        sharedVaultId.isAcceptableOrUnknown(
          data['shared_vault_id']!,
          _sharedVaultIdMeta,
        ),
      );
    }
    if (data.containsKey('is_pinned')) {
      context.handle(
        _isPinnedMeta,
        isPinned.isAcceptableOrUnknown(data['is_pinned']!, _isPinnedMeta),
      );
    }
    if (data.containsKey('color_label')) {
      context.handle(
        _colorLabelMeta,
        colorLabel.isAcceptableOrUnknown(data['color_label']!, _colorLabelMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  VaultItemEntity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultItemEntity(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}type'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      username: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}username'],
      )!,
      secret: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}secret'],
      ),
      password: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password'],
      ),
      mnemonic: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mnemonic'],
      ),
      privateKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}private_key'],
      ),
      address: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}address'],
      ),
      network: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}network'],
      ),
      period: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}period'],
      )!,
      isFavorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_favorite'],
      )!,
      url: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}url'],
      ),
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      category: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}category'],
      ),
      email: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}email'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      passwordHistory: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}password_history'],
      ),
      passwordLastChanged: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}password_last_changed'],
      ),
      passwordDuration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}password_duration'],
      ),
      accounts: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}accounts'],
      ),
      isDeleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_deleted'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
      tags: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tags'],
      ),
      sharedVaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shared_vault_id'],
      ),
      isPinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_pinned'],
      )!,
      colorLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}color_label'],
      ),
    );
  }

  @override
  $VaultItemsTable createAlias(String alias) {
    return $VaultItemsTable(attachedDatabase, alias);
  }
}

class VaultItemEntity extends DataClass implements Insertable<VaultItemEntity> {
  final String id;
  final int type;
  final String title;
  final String username;
  final String? secret;
  final String? password;
  final String? mnemonic;
  final String? privateKey;
  final String? address;
  final String? network;
  final int period;
  final bool isFavorite;
  final String? url;
  final String? note;
  final String? category;
  final String? email;
  final DateTime updatedAt;
  final String? passwordHistory;
  final DateTime? passwordLastChanged;
  final int? passwordDuration;
  final String? accounts;
  final bool isDeleted;
  final DateTime? deletedAt;
  final String? tags;
  final String? sharedVaultId;
  final bool isPinned;
  final String? colorLabel;
  const VaultItemEntity({
    required this.id,
    required this.type,
    required this.title,
    required this.username,
    this.secret,
    this.password,
    this.mnemonic,
    this.privateKey,
    this.address,
    this.network,
    required this.period,
    required this.isFavorite,
    this.url,
    this.note,
    this.category,
    this.email,
    required this.updatedAt,
    this.passwordHistory,
    this.passwordLastChanged,
    this.passwordDuration,
    this.accounts,
    required this.isDeleted,
    this.deletedAt,
    this.tags,
    this.sharedVaultId,
    required this.isPinned,
    this.colorLabel,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['type'] = Variable<int>(type);
    map['title'] = Variable<String>(title);
    map['username'] = Variable<String>(username);
    if (!nullToAbsent || secret != null) {
      map['secret'] = Variable<String>(secret);
    }
    if (!nullToAbsent || password != null) {
      map['password'] = Variable<String>(password);
    }
    if (!nullToAbsent || mnemonic != null) {
      map['mnemonic'] = Variable<String>(mnemonic);
    }
    if (!nullToAbsent || privateKey != null) {
      map['private_key'] = Variable<String>(privateKey);
    }
    if (!nullToAbsent || address != null) {
      map['address'] = Variable<String>(address);
    }
    if (!nullToAbsent || network != null) {
      map['network'] = Variable<String>(network);
    }
    map['period'] = Variable<int>(period);
    map['is_favorite'] = Variable<bool>(isFavorite);
    if (!nullToAbsent || url != null) {
      map['url'] = Variable<String>(url);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    if (!nullToAbsent || category != null) {
      map['category'] = Variable<String>(category);
    }
    if (!nullToAbsent || email != null) {
      map['email'] = Variable<String>(email);
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || passwordHistory != null) {
      map['password_history'] = Variable<String>(passwordHistory);
    }
    if (!nullToAbsent || passwordLastChanged != null) {
      map['password_last_changed'] = Variable<DateTime>(passwordLastChanged);
    }
    if (!nullToAbsent || passwordDuration != null) {
      map['password_duration'] = Variable<int>(passwordDuration);
    }
    if (!nullToAbsent || accounts != null) {
      map['accounts'] = Variable<String>(accounts);
    }
    map['is_deleted'] = Variable<bool>(isDeleted);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    if (!nullToAbsent || tags != null) {
      map['tags'] = Variable<String>(tags);
    }
    if (!nullToAbsent || sharedVaultId != null) {
      map['shared_vault_id'] = Variable<String>(sharedVaultId);
    }
    map['is_pinned'] = Variable<bool>(isPinned);
    if (!nullToAbsent || colorLabel != null) {
      map['color_label'] = Variable<String>(colorLabel);
    }
    return map;
  }

  VaultItemsCompanion toCompanion(bool nullToAbsent) {
    return VaultItemsCompanion(
      id: Value(id),
      type: Value(type),
      title: Value(title),
      username: Value(username),
      secret: secret == null && nullToAbsent
          ? const Value.absent()
          : Value(secret),
      password: password == null && nullToAbsent
          ? const Value.absent()
          : Value(password),
      mnemonic: mnemonic == null && nullToAbsent
          ? const Value.absent()
          : Value(mnemonic),
      privateKey: privateKey == null && nullToAbsent
          ? const Value.absent()
          : Value(privateKey),
      address: address == null && nullToAbsent
          ? const Value.absent()
          : Value(address),
      network: network == null && nullToAbsent
          ? const Value.absent()
          : Value(network),
      period: Value(period),
      isFavorite: Value(isFavorite),
      url: url == null && nullToAbsent ? const Value.absent() : Value(url),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      category: category == null && nullToAbsent
          ? const Value.absent()
          : Value(category),
      email: email == null && nullToAbsent
          ? const Value.absent()
          : Value(email),
      updatedAt: Value(updatedAt),
      passwordHistory: passwordHistory == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordHistory),
      passwordLastChanged: passwordLastChanged == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordLastChanged),
      passwordDuration: passwordDuration == null && nullToAbsent
          ? const Value.absent()
          : Value(passwordDuration),
      accounts: accounts == null && nullToAbsent
          ? const Value.absent()
          : Value(accounts),
      isDeleted: Value(isDeleted),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
      tags: tags == null && nullToAbsent ? const Value.absent() : Value(tags),
      sharedVaultId: sharedVaultId == null && nullToAbsent
          ? const Value.absent()
          : Value(sharedVaultId),
      isPinned: Value(isPinned),
      colorLabel: colorLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(colorLabel),
    );
  }

  factory VaultItemEntity.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return VaultItemEntity(
      id: serializer.fromJson<String>(json['id']),
      type: serializer.fromJson<int>(json['type']),
      title: serializer.fromJson<String>(json['title']),
      username: serializer.fromJson<String>(json['username']),
      secret: serializer.fromJson<String?>(json['secret']),
      password: serializer.fromJson<String?>(json['password']),
      mnemonic: serializer.fromJson<String?>(json['mnemonic']),
      privateKey: serializer.fromJson<String?>(json['privateKey']),
      address: serializer.fromJson<String?>(json['address']),
      network: serializer.fromJson<String?>(json['network']),
      period: serializer.fromJson<int>(json['period']),
      isFavorite: serializer.fromJson<bool>(json['isFavorite']),
      url: serializer.fromJson<String?>(json['url']),
      note: serializer.fromJson<String?>(json['note']),
      category: serializer.fromJson<String?>(json['category']),
      email: serializer.fromJson<String?>(json['email']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      passwordHistory: serializer.fromJson<String?>(json['passwordHistory']),
      passwordLastChanged: serializer.fromJson<DateTime?>(
        json['passwordLastChanged'],
      ),
      passwordDuration: serializer.fromJson<int?>(json['passwordDuration']),
      accounts: serializer.fromJson<String?>(json['accounts']),
      isDeleted: serializer.fromJson<bool>(json['isDeleted']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
      tags: serializer.fromJson<String?>(json['tags']),
      sharedVaultId: serializer.fromJson<String?>(json['sharedVaultId']),
      isPinned: serializer.fromJson<bool>(json['isPinned']),
      colorLabel: serializer.fromJson<String?>(json['colorLabel']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'type': serializer.toJson<int>(type),
      'title': serializer.toJson<String>(title),
      'username': serializer.toJson<String>(username),
      'secret': serializer.toJson<String?>(secret),
      'password': serializer.toJson<String?>(password),
      'mnemonic': serializer.toJson<String?>(mnemonic),
      'privateKey': serializer.toJson<String?>(privateKey),
      'address': serializer.toJson<String?>(address),
      'network': serializer.toJson<String?>(network),
      'period': serializer.toJson<int>(period),
      'isFavorite': serializer.toJson<bool>(isFavorite),
      'url': serializer.toJson<String?>(url),
      'note': serializer.toJson<String?>(note),
      'category': serializer.toJson<String?>(category),
      'email': serializer.toJson<String?>(email),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'passwordHistory': serializer.toJson<String?>(passwordHistory),
      'passwordLastChanged': serializer.toJson<DateTime?>(passwordLastChanged),
      'passwordDuration': serializer.toJson<int?>(passwordDuration),
      'accounts': serializer.toJson<String?>(accounts),
      'isDeleted': serializer.toJson<bool>(isDeleted),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
      'tags': serializer.toJson<String?>(tags),
      'sharedVaultId': serializer.toJson<String?>(sharedVaultId),
      'isPinned': serializer.toJson<bool>(isPinned),
      'colorLabel': serializer.toJson<String?>(colorLabel),
    };
  }

  VaultItemEntity copyWith({
    String? id,
    int? type,
    String? title,
    String? username,
    Value<String?> secret = const Value.absent(),
    Value<String?> password = const Value.absent(),
    Value<String?> mnemonic = const Value.absent(),
    Value<String?> privateKey = const Value.absent(),
    Value<String?> address = const Value.absent(),
    Value<String?> network = const Value.absent(),
    int? period,
    bool? isFavorite,
    Value<String?> url = const Value.absent(),
    Value<String?> note = const Value.absent(),
    Value<String?> category = const Value.absent(),
    Value<String?> email = const Value.absent(),
    DateTime? updatedAt,
    Value<String?> passwordHistory = const Value.absent(),
    Value<DateTime?> passwordLastChanged = const Value.absent(),
    Value<int?> passwordDuration = const Value.absent(),
    Value<String?> accounts = const Value.absent(),
    bool? isDeleted,
    Value<DateTime?> deletedAt = const Value.absent(),
    Value<String?> tags = const Value.absent(),
    Value<String?> sharedVaultId = const Value.absent(),
    bool? isPinned,
    Value<String?> colorLabel = const Value.absent(),
  }) => VaultItemEntity(
    id: id ?? this.id,
    type: type ?? this.type,
    title: title ?? this.title,
    username: username ?? this.username,
    secret: secret.present ? secret.value : this.secret,
    password: password.present ? password.value : this.password,
    mnemonic: mnemonic.present ? mnemonic.value : this.mnemonic,
    privateKey: privateKey.present ? privateKey.value : this.privateKey,
    address: address.present ? address.value : this.address,
    network: network.present ? network.value : this.network,
    period: period ?? this.period,
    isFavorite: isFavorite ?? this.isFavorite,
    url: url.present ? url.value : this.url,
    note: note.present ? note.value : this.note,
    category: category.present ? category.value : this.category,
    email: email.present ? email.value : this.email,
    updatedAt: updatedAt ?? this.updatedAt,
    passwordHistory: passwordHistory.present
        ? passwordHistory.value
        : this.passwordHistory,
    passwordLastChanged: passwordLastChanged.present
        ? passwordLastChanged.value
        : this.passwordLastChanged,
    passwordDuration: passwordDuration.present
        ? passwordDuration.value
        : this.passwordDuration,
    accounts: accounts.present ? accounts.value : this.accounts,
    isDeleted: isDeleted ?? this.isDeleted,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
    tags: tags.present ? tags.value : this.tags,
    sharedVaultId: sharedVaultId.present
        ? sharedVaultId.value
        : this.sharedVaultId,
    isPinned: isPinned ?? this.isPinned,
    colorLabel: colorLabel.present ? colorLabel.value : this.colorLabel,
  );
  VaultItemEntity copyWithCompanion(VaultItemsCompanion data) {
    return VaultItemEntity(
      id: data.id.present ? data.id.value : this.id,
      type: data.type.present ? data.type.value : this.type,
      title: data.title.present ? data.title.value : this.title,
      username: data.username.present ? data.username.value : this.username,
      secret: data.secret.present ? data.secret.value : this.secret,
      password: data.password.present ? data.password.value : this.password,
      mnemonic: data.mnemonic.present ? data.mnemonic.value : this.mnemonic,
      privateKey: data.privateKey.present
          ? data.privateKey.value
          : this.privateKey,
      address: data.address.present ? data.address.value : this.address,
      network: data.network.present ? data.network.value : this.network,
      period: data.period.present ? data.period.value : this.period,
      isFavorite: data.isFavorite.present
          ? data.isFavorite.value
          : this.isFavorite,
      url: data.url.present ? data.url.value : this.url,
      note: data.note.present ? data.note.value : this.note,
      category: data.category.present ? data.category.value : this.category,
      email: data.email.present ? data.email.value : this.email,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      passwordHistory: data.passwordHistory.present
          ? data.passwordHistory.value
          : this.passwordHistory,
      passwordLastChanged: data.passwordLastChanged.present
          ? data.passwordLastChanged.value
          : this.passwordLastChanged,
      passwordDuration: data.passwordDuration.present
          ? data.passwordDuration.value
          : this.passwordDuration,
      accounts: data.accounts.present ? data.accounts.value : this.accounts,
      isDeleted: data.isDeleted.present ? data.isDeleted.value : this.isDeleted,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
      tags: data.tags.present ? data.tags.value : this.tags,
      sharedVaultId: data.sharedVaultId.present
          ? data.sharedVaultId.value
          : this.sharedVaultId,
      isPinned: data.isPinned.present ? data.isPinned.value : this.isPinned,
      colorLabel: data.colorLabel.present
          ? data.colorLabel.value
          : this.colorLabel,
    );
  }

  @override
  String toString() {
    return (StringBuffer('VaultItemEntity(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('title: $title, ')
          ..write('username: $username, ')
          ..write('secret: $secret, ')
          ..write('password: $password, ')
          ..write('mnemonic: $mnemonic, ')
          ..write('privateKey: $privateKey, ')
          ..write('address: $address, ')
          ..write('network: $network, ')
          ..write('period: $period, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('url: $url, ')
          ..write('note: $note, ')
          ..write('category: $category, ')
          ..write('email: $email, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('passwordHistory: $passwordHistory, ')
          ..write('passwordLastChanged: $passwordLastChanged, ')
          ..write('passwordDuration: $passwordDuration, ')
          ..write('accounts: $accounts, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('tags: $tags, ')
          ..write('sharedVaultId: $sharedVaultId, ')
          ..write('isPinned: $isPinned, ')
          ..write('colorLabel: $colorLabel')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    type,
    title,
    username,
    secret,
    password,
    mnemonic,
    privateKey,
    address,
    network,
    period,
    isFavorite,
    url,
    note,
    category,
    email,
    updatedAt,
    passwordHistory,
    passwordLastChanged,
    passwordDuration,
    accounts,
    isDeleted,
    deletedAt,
    tags,
    sharedVaultId,
    isPinned,
    colorLabel,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is VaultItemEntity &&
          other.id == this.id &&
          other.type == this.type &&
          other.title == this.title &&
          other.username == this.username &&
          other.secret == this.secret &&
          other.password == this.password &&
          other.mnemonic == this.mnemonic &&
          other.privateKey == this.privateKey &&
          other.address == this.address &&
          other.network == this.network &&
          other.period == this.period &&
          other.isFavorite == this.isFavorite &&
          other.url == this.url &&
          other.note == this.note &&
          other.category == this.category &&
          other.email == this.email &&
          other.updatedAt == this.updatedAt &&
          other.passwordHistory == this.passwordHistory &&
          other.passwordLastChanged == this.passwordLastChanged &&
          other.passwordDuration == this.passwordDuration &&
          other.accounts == this.accounts &&
          other.isDeleted == this.isDeleted &&
          other.deletedAt == this.deletedAt &&
          other.tags == this.tags &&
          other.sharedVaultId == this.sharedVaultId &&
          other.isPinned == this.isPinned &&
          other.colorLabel == this.colorLabel);
}

class VaultItemsCompanion extends UpdateCompanion<VaultItemEntity> {
  final Value<String> id;
  final Value<int> type;
  final Value<String> title;
  final Value<String> username;
  final Value<String?> secret;
  final Value<String?> password;
  final Value<String?> mnemonic;
  final Value<String?> privateKey;
  final Value<String?> address;
  final Value<String?> network;
  final Value<int> period;
  final Value<bool> isFavorite;
  final Value<String?> url;
  final Value<String?> note;
  final Value<String?> category;
  final Value<String?> email;
  final Value<DateTime> updatedAt;
  final Value<String?> passwordHistory;
  final Value<DateTime?> passwordLastChanged;
  final Value<int?> passwordDuration;
  final Value<String?> accounts;
  final Value<bool> isDeleted;
  final Value<DateTime?> deletedAt;
  final Value<String?> tags;
  final Value<String?> sharedVaultId;
  final Value<bool> isPinned;
  final Value<String?> colorLabel;
  final Value<int> rowid;
  const VaultItemsCompanion({
    this.id = const Value.absent(),
    this.type = const Value.absent(),
    this.title = const Value.absent(),
    this.username = const Value.absent(),
    this.secret = const Value.absent(),
    this.password = const Value.absent(),
    this.mnemonic = const Value.absent(),
    this.privateKey = const Value.absent(),
    this.address = const Value.absent(),
    this.network = const Value.absent(),
    this.period = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.url = const Value.absent(),
    this.note = const Value.absent(),
    this.category = const Value.absent(),
    this.email = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.passwordHistory = const Value.absent(),
    this.passwordLastChanged = const Value.absent(),
    this.passwordDuration = const Value.absent(),
    this.accounts = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.tags = const Value.absent(),
    this.sharedVaultId = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.colorLabel = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  VaultItemsCompanion.insert({
    required String id,
    required int type,
    required String title,
    required String username,
    this.secret = const Value.absent(),
    this.password = const Value.absent(),
    this.mnemonic = const Value.absent(),
    this.privateKey = const Value.absent(),
    this.address = const Value.absent(),
    this.network = const Value.absent(),
    this.period = const Value.absent(),
    this.isFavorite = const Value.absent(),
    this.url = const Value.absent(),
    this.note = const Value.absent(),
    this.category = const Value.absent(),
    this.email = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.passwordHistory = const Value.absent(),
    this.passwordLastChanged = const Value.absent(),
    this.passwordDuration = const Value.absent(),
    this.accounts = const Value.absent(),
    this.isDeleted = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.tags = const Value.absent(),
    this.sharedVaultId = const Value.absent(),
    this.isPinned = const Value.absent(),
    this.colorLabel = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       type = Value(type),
       title = Value(title),
       username = Value(username);
  static Insertable<VaultItemEntity> custom({
    Expression<String>? id,
    Expression<int>? type,
    Expression<String>? title,
    Expression<String>? username,
    Expression<String>? secret,
    Expression<String>? password,
    Expression<String>? mnemonic,
    Expression<String>? privateKey,
    Expression<String>? address,
    Expression<String>? network,
    Expression<int>? period,
    Expression<bool>? isFavorite,
    Expression<String>? url,
    Expression<String>? note,
    Expression<String>? category,
    Expression<String>? email,
    Expression<DateTime>? updatedAt,
    Expression<String>? passwordHistory,
    Expression<DateTime>? passwordLastChanged,
    Expression<int>? passwordDuration,
    Expression<String>? accounts,
    Expression<bool>? isDeleted,
    Expression<DateTime>? deletedAt,
    Expression<String>? tags,
    Expression<String>? sharedVaultId,
    Expression<bool>? isPinned,
    Expression<String>? colorLabel,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (type != null) 'type': type,
      if (title != null) 'title': title,
      if (username != null) 'username': username,
      if (secret != null) 'secret': secret,
      if (password != null) 'password': password,
      if (mnemonic != null) 'mnemonic': mnemonic,
      if (privateKey != null) 'private_key': privateKey,
      if (address != null) 'address': address,
      if (network != null) 'network': network,
      if (period != null) 'period': period,
      if (isFavorite != null) 'is_favorite': isFavorite,
      if (url != null) 'url': url,
      if (note != null) 'note': note,
      if (category != null) 'category': category,
      if (email != null) 'email': email,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (passwordHistory != null) 'password_history': passwordHistory,
      if (passwordLastChanged != null)
        'password_last_changed': passwordLastChanged,
      if (passwordDuration != null) 'password_duration': passwordDuration,
      if (accounts != null) 'accounts': accounts,
      if (isDeleted != null) 'is_deleted': isDeleted,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (tags != null) 'tags': tags,
      if (sharedVaultId != null) 'shared_vault_id': sharedVaultId,
      if (isPinned != null) 'is_pinned': isPinned,
      if (colorLabel != null) 'color_label': colorLabel,
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultItemsCompanion copyWith({
    Value<String>? id,
    Value<int>? type,
    Value<String>? title,
    Value<String>? username,
    Value<String?>? secret,
    Value<String?>? password,
    Value<String?>? mnemonic,
    Value<String?>? privateKey,
    Value<String?>? address,
    Value<String?>? network,
    Value<int>? period,
    Value<bool>? isFavorite,
    Value<String?>? url,
    Value<String?>? note,
    Value<String?>? category,
    Value<String?>? email,
    Value<DateTime>? updatedAt,
    Value<String?>? passwordHistory,
    Value<DateTime?>? passwordLastChanged,
    Value<int?>? passwordDuration,
    Value<String?>? accounts,
    Value<bool>? isDeleted,
    Value<DateTime?>? deletedAt,
    Value<String?>? tags,
    Value<String?>? sharedVaultId,
    Value<bool>? isPinned,
    Value<String?>? colorLabel,
    Value<int>? rowid,
  }) {
    return VaultItemsCompanion(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      username: username ?? this.username,
      secret: secret ?? this.secret,
      password: password ?? this.password,
      mnemonic: mnemonic ?? this.mnemonic,
      privateKey: privateKey ?? this.privateKey,
      address: address ?? this.address,
      network: network ?? this.network,
      period: period ?? this.period,
      isFavorite: isFavorite ?? this.isFavorite,
      url: url ?? this.url,
      note: note ?? this.note,
      category: category ?? this.category,
      email: email ?? this.email,
      updatedAt: updatedAt ?? this.updatedAt,
      passwordHistory: passwordHistory ?? this.passwordHistory,
      passwordLastChanged: passwordLastChanged ?? this.passwordLastChanged,
      passwordDuration: passwordDuration ?? this.passwordDuration,
      accounts: accounts ?? this.accounts,
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      tags: tags ?? this.tags,
      sharedVaultId: sharedVaultId ?? this.sharedVaultId,
      isPinned: isPinned ?? this.isPinned,
      colorLabel: colorLabel ?? this.colorLabel,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (type.present) {
      map['type'] = Variable<int>(type.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (username.present) {
      map['username'] = Variable<String>(username.value);
    }
    if (secret.present) {
      map['secret'] = Variable<String>(secret.value);
    }
    if (password.present) {
      map['password'] = Variable<String>(password.value);
    }
    if (mnemonic.present) {
      map['mnemonic'] = Variable<String>(mnemonic.value);
    }
    if (privateKey.present) {
      map['private_key'] = Variable<String>(privateKey.value);
    }
    if (address.present) {
      map['address'] = Variable<String>(address.value);
    }
    if (network.present) {
      map['network'] = Variable<String>(network.value);
    }
    if (period.present) {
      map['period'] = Variable<int>(period.value);
    }
    if (isFavorite.present) {
      map['is_favorite'] = Variable<bool>(isFavorite.value);
    }
    if (url.present) {
      map['url'] = Variable<String>(url.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (category.present) {
      map['category'] = Variable<String>(category.value);
    }
    if (email.present) {
      map['email'] = Variable<String>(email.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (passwordHistory.present) {
      map['password_history'] = Variable<String>(passwordHistory.value);
    }
    if (passwordLastChanged.present) {
      map['password_last_changed'] = Variable<DateTime>(
        passwordLastChanged.value,
      );
    }
    if (passwordDuration.present) {
      map['password_duration'] = Variable<int>(passwordDuration.value);
    }
    if (accounts.present) {
      map['accounts'] = Variable<String>(accounts.value);
    }
    if (isDeleted.present) {
      map['is_deleted'] = Variable<bool>(isDeleted.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (tags.present) {
      map['tags'] = Variable<String>(tags.value);
    }
    if (sharedVaultId.present) {
      map['shared_vault_id'] = Variable<String>(sharedVaultId.value);
    }
    if (isPinned.present) {
      map['is_pinned'] = Variable<bool>(isPinned.value);
    }
    if (colorLabel.present) {
      map['color_label'] = Variable<String>(colorLabel.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('VaultItemsCompanion(')
          ..write('id: $id, ')
          ..write('type: $type, ')
          ..write('title: $title, ')
          ..write('username: $username, ')
          ..write('secret: $secret, ')
          ..write('password: $password, ')
          ..write('mnemonic: $mnemonic, ')
          ..write('privateKey: $privateKey, ')
          ..write('address: $address, ')
          ..write('network: $network, ')
          ..write('period: $period, ')
          ..write('isFavorite: $isFavorite, ')
          ..write('url: $url, ')
          ..write('note: $note, ')
          ..write('category: $category, ')
          ..write('email: $email, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('passwordHistory: $passwordHistory, ')
          ..write('passwordLastChanged: $passwordLastChanged, ')
          ..write('passwordDuration: $passwordDuration, ')
          ..write('accounts: $accounts, ')
          ..write('isDeleted: $isDeleted, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('tags: $tags, ')
          ..write('sharedVaultId: $sharedVaultId, ')
          ..write('isPinned: $isPinned, ')
          ..write('colorLabel: $colorLabel, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SharedMembersTable extends SharedMembers
    with TableInfo<$SharedMembersTable, SharedMemberEntity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SharedMembersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _vaultIdMeta = const VerificationMeta(
    'vaultId',
  );
  @override
  late final GeneratedColumn<String> vaultId = GeneratedColumn<String>(
    'vault_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES shared_vaults (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _userPublicKeyMeta = const VerificationMeta(
    'userPublicKey',
  );
  @override
  late final GeneratedColumn<String> userPublicKey = GeneratedColumn<String>(
    'user_public_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _encryptedVaultKeyMeta = const VerificationMeta(
    'encryptedVaultKey',
  );
  @override
  late final GeneratedColumn<String> encryptedVaultKey =
      GeneratedColumn<String>(
        'encrypted_vault_key',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<int> role = GeneratedColumn<int>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    vaultId,
    userPublicKey,
    encryptedVaultKey,
    role,
    name,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'shared_members';
  @override
  VerificationContext validateIntegrity(
    Insertable<SharedMemberEntity> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('vault_id')) {
      context.handle(
        _vaultIdMeta,
        vaultId.isAcceptableOrUnknown(data['vault_id']!, _vaultIdMeta),
      );
    } else if (isInserting) {
      context.missing(_vaultIdMeta);
    }
    if (data.containsKey('user_public_key')) {
      context.handle(
        _userPublicKeyMeta,
        userPublicKey.isAcceptableOrUnknown(
          data['user_public_key']!,
          _userPublicKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_userPublicKeyMeta);
    }
    if (data.containsKey('encrypted_vault_key')) {
      context.handle(
        _encryptedVaultKeyMeta,
        encryptedVaultKey.isAcceptableOrUnknown(
          data['encrypted_vault_key']!,
          _encryptedVaultKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_encryptedVaultKeyMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SharedMemberEntity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SharedMemberEntity(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      vaultId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}vault_id'],
      )!,
      userPublicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_public_key'],
      )!,
      encryptedVaultKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}encrypted_vault_key'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}role'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      ),
    );
  }

  @override
  $SharedMembersTable createAlias(String alias) {
    return $SharedMembersTable(attachedDatabase, alias);
  }
}

class SharedMemberEntity extends DataClass
    implements Insertable<SharedMemberEntity> {
  final String id;
  final String vaultId;
  final String userPublicKey;
  final String encryptedVaultKey;
  final int role;
  final String? name;
  const SharedMemberEntity({
    required this.id,
    required this.vaultId,
    required this.userPublicKey,
    required this.encryptedVaultKey,
    required this.role,
    this.name,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['vault_id'] = Variable<String>(vaultId);
    map['user_public_key'] = Variable<String>(userPublicKey);
    map['encrypted_vault_key'] = Variable<String>(encryptedVaultKey);
    map['role'] = Variable<int>(role);
    if (!nullToAbsent || name != null) {
      map['name'] = Variable<String>(name);
    }
    return map;
  }

  SharedMembersCompanion toCompanion(bool nullToAbsent) {
    return SharedMembersCompanion(
      id: Value(id),
      vaultId: Value(vaultId),
      userPublicKey: Value(userPublicKey),
      encryptedVaultKey: Value(encryptedVaultKey),
      role: Value(role),
      name: name == null && nullToAbsent ? const Value.absent() : Value(name),
    );
  }

  factory SharedMemberEntity.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SharedMemberEntity(
      id: serializer.fromJson<String>(json['id']),
      vaultId: serializer.fromJson<String>(json['vaultId']),
      userPublicKey: serializer.fromJson<String>(json['userPublicKey']),
      encryptedVaultKey: serializer.fromJson<String>(json['encryptedVaultKey']),
      role: serializer.fromJson<int>(json['role']),
      name: serializer.fromJson<String?>(json['name']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'vaultId': serializer.toJson<String>(vaultId),
      'userPublicKey': serializer.toJson<String>(userPublicKey),
      'encryptedVaultKey': serializer.toJson<String>(encryptedVaultKey),
      'role': serializer.toJson<int>(role),
      'name': serializer.toJson<String?>(name),
    };
  }

  SharedMemberEntity copyWith({
    String? id,
    String? vaultId,
    String? userPublicKey,
    String? encryptedVaultKey,
    int? role,
    Value<String?> name = const Value.absent(),
  }) => SharedMemberEntity(
    id: id ?? this.id,
    vaultId: vaultId ?? this.vaultId,
    userPublicKey: userPublicKey ?? this.userPublicKey,
    encryptedVaultKey: encryptedVaultKey ?? this.encryptedVaultKey,
    role: role ?? this.role,
    name: name.present ? name.value : this.name,
  );
  SharedMemberEntity copyWithCompanion(SharedMembersCompanion data) {
    return SharedMemberEntity(
      id: data.id.present ? data.id.value : this.id,
      vaultId: data.vaultId.present ? data.vaultId.value : this.vaultId,
      userPublicKey: data.userPublicKey.present
          ? data.userPublicKey.value
          : this.userPublicKey,
      encryptedVaultKey: data.encryptedVaultKey.present
          ? data.encryptedVaultKey.value
          : this.encryptedVaultKey,
      role: data.role.present ? data.role.value : this.role,
      name: data.name.present ? data.name.value : this.name,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SharedMemberEntity(')
          ..write('id: $id, ')
          ..write('vaultId: $vaultId, ')
          ..write('userPublicKey: $userPublicKey, ')
          ..write('encryptedVaultKey: $encryptedVaultKey, ')
          ..write('role: $role, ')
          ..write('name: $name')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, vaultId, userPublicKey, encryptedVaultKey, role, name);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SharedMemberEntity &&
          other.id == this.id &&
          other.vaultId == this.vaultId &&
          other.userPublicKey == this.userPublicKey &&
          other.encryptedVaultKey == this.encryptedVaultKey &&
          other.role == this.role &&
          other.name == this.name);
}

class SharedMembersCompanion extends UpdateCompanion<SharedMemberEntity> {
  final Value<String> id;
  final Value<String> vaultId;
  final Value<String> userPublicKey;
  final Value<String> encryptedVaultKey;
  final Value<int> role;
  final Value<String?> name;
  final Value<int> rowid;
  const SharedMembersCompanion({
    this.id = const Value.absent(),
    this.vaultId = const Value.absent(),
    this.userPublicKey = const Value.absent(),
    this.encryptedVaultKey = const Value.absent(),
    this.role = const Value.absent(),
    this.name = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SharedMembersCompanion.insert({
    required String id,
    required String vaultId,
    required String userPublicKey,
    required String encryptedVaultKey,
    required int role,
    this.name = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       vaultId = Value(vaultId),
       userPublicKey = Value(userPublicKey),
       encryptedVaultKey = Value(encryptedVaultKey),
       role = Value(role);
  static Insertable<SharedMemberEntity> custom({
    Expression<String>? id,
    Expression<String>? vaultId,
    Expression<String>? userPublicKey,
    Expression<String>? encryptedVaultKey,
    Expression<int>? role,
    Expression<String>? name,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (vaultId != null) 'vault_id': vaultId,
      if (userPublicKey != null) 'user_public_key': userPublicKey,
      if (encryptedVaultKey != null) 'encrypted_vault_key': encryptedVaultKey,
      if (role != null) 'role': role,
      if (name != null) 'name': name,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SharedMembersCompanion copyWith({
    Value<String>? id,
    Value<String>? vaultId,
    Value<String>? userPublicKey,
    Value<String>? encryptedVaultKey,
    Value<int>? role,
    Value<String?>? name,
    Value<int>? rowid,
  }) {
    return SharedMembersCompanion(
      id: id ?? this.id,
      vaultId: vaultId ?? this.vaultId,
      userPublicKey: userPublicKey ?? this.userPublicKey,
      encryptedVaultKey: encryptedVaultKey ?? this.encryptedVaultKey,
      role: role ?? this.role,
      name: name ?? this.name,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (vaultId.present) {
      map['vault_id'] = Variable<String>(vaultId.value);
    }
    if (userPublicKey.present) {
      map['user_public_key'] = Variable<String>(userPublicKey.value);
    }
    if (encryptedVaultKey.present) {
      map['encrypted_vault_key'] = Variable<String>(encryptedVaultKey.value);
    }
    if (role.present) {
      map['role'] = Variable<int>(role.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SharedMembersCompanion(')
          ..write('id: $id, ')
          ..write('vaultId: $vaultId, ')
          ..write('userPublicKey: $userPublicKey, ')
          ..write('encryptedVaultKey: $encryptedVaultKey, ')
          ..write('role: $role, ')
          ..write('name: $name, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SharedVaultsTable sharedVaults = $SharedVaultsTable(this);
  late final $VaultItemsTable vaultItems = $VaultItemsTable(this);
  late final $SharedMembersTable sharedMembers = $SharedMembersTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sharedVaults,
    vaultItems,
    sharedMembers,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'shared_vaults',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('shared_members', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$SharedVaultsTableCreateCompanionBuilder =
    SharedVaultsCompanion Function({
      required String id,
      required String name,
      required String encryptedVaultKey,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<bool> isDiscoverable,
      Value<int> rowid,
    });
typedef $$SharedVaultsTableUpdateCompanionBuilder =
    SharedVaultsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String> encryptedVaultKey,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<bool> isDiscoverable,
      Value<int> rowid,
    });

final class $$SharedVaultsTableReferences
    extends
        BaseReferences<_$AppDatabase, $SharedVaultsTable, SharedVaultEntity> {
  $$SharedVaultsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$VaultItemsTable, List<VaultItemEntity>>
  _vaultItemsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.vaultItems,
    aliasName: $_aliasNameGenerator(
      db.sharedVaults.id,
      db.vaultItems.sharedVaultId,
    ),
  );

  $$VaultItemsTableProcessedTableManager get vaultItemsRefs {
    final manager = $$VaultItemsTableTableManager(
      $_db,
      $_db.vaultItems,
    ).filter((f) => f.sharedVaultId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_vaultItemsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SharedMembersTable, List<SharedMemberEntity>>
  _sharedMembersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.sharedMembers,
    aliasName: $_aliasNameGenerator(
      db.sharedVaults.id,
      db.sharedMembers.vaultId,
    ),
  );

  $$SharedMembersTableProcessedTableManager get sharedMembersRefs {
    final manager = $$SharedMembersTableTableManager(
      $_db,
      $_db.sharedMembers,
    ).filter((f) => f.vaultId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_sharedMembersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SharedVaultsTableFilterComposer
    extends Composer<_$AppDatabase, $SharedVaultsTable> {
  $$SharedVaultsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encryptedVaultKey => $composableBuilder(
    column: $table.encryptedVaultKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDiscoverable => $composableBuilder(
    column: $table.isDiscoverable,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> vaultItemsRefs(
    Expression<bool> Function($$VaultItemsTableFilterComposer f) f,
  ) {
    final $$VaultItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.vaultItems,
      getReferencedColumn: (t) => t.sharedVaultId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$VaultItemsTableFilterComposer(
            $db: $db,
            $table: $db.vaultItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> sharedMembersRefs(
    Expression<bool> Function($$SharedMembersTableFilterComposer f) f,
  ) {
    final $$SharedMembersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sharedMembers,
      getReferencedColumn: (t) => t.vaultId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedMembersTableFilterComposer(
            $db: $db,
            $table: $db.sharedMembers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SharedVaultsTableOrderingComposer
    extends Composer<_$AppDatabase, $SharedVaultsTable> {
  $$SharedVaultsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encryptedVaultKey => $composableBuilder(
    column: $table.encryptedVaultKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDiscoverable => $composableBuilder(
    column: $table.isDiscoverable,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SharedVaultsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SharedVaultsTable> {
  $$SharedVaultsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get encryptedVaultKey => $composableBuilder(
    column: $table.encryptedVaultKey,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get isDiscoverable => $composableBuilder(
    column: $table.isDiscoverable,
    builder: (column) => column,
  );

  Expression<T> vaultItemsRefs<T extends Object>(
    Expression<T> Function($$VaultItemsTableAnnotationComposer a) f,
  ) {
    final $$VaultItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.vaultItems,
      getReferencedColumn: (t) => t.sharedVaultId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$VaultItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.vaultItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> sharedMembersRefs<T extends Object>(
    Expression<T> Function($$SharedMembersTableAnnotationComposer a) f,
  ) {
    final $$SharedMembersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.sharedMembers,
      getReferencedColumn: (t) => t.vaultId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedMembersTableAnnotationComposer(
            $db: $db,
            $table: $db.sharedMembers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SharedVaultsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SharedVaultsTable,
          SharedVaultEntity,
          $$SharedVaultsTableFilterComposer,
          $$SharedVaultsTableOrderingComposer,
          $$SharedVaultsTableAnnotationComposer,
          $$SharedVaultsTableCreateCompanionBuilder,
          $$SharedVaultsTableUpdateCompanionBuilder,
          (SharedVaultEntity, $$SharedVaultsTableReferences),
          SharedVaultEntity,
          PrefetchHooks Function({bool vaultItemsRefs, bool sharedMembersRefs})
        > {
  $$SharedVaultsTableTableManager(_$AppDatabase db, $SharedVaultsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SharedVaultsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SharedVaultsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SharedVaultsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> encryptedVaultKey = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<bool> isDiscoverable = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SharedVaultsCompanion(
                id: id,
                name: name,
                encryptedVaultKey: encryptedVaultKey,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isDiscoverable: isDiscoverable,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String encryptedVaultKey,
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<bool> isDiscoverable = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SharedVaultsCompanion.insert(
                id: id,
                name: name,
                encryptedVaultKey: encryptedVaultKey,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isDiscoverable: isDiscoverable,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SharedVaultsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({vaultItemsRefs = false, sharedMembersRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (vaultItemsRefs) db.vaultItems,
                    if (sharedMembersRefs) db.sharedMembers,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (vaultItemsRefs)
                        await $_getPrefetchedData<
                          SharedVaultEntity,
                          $SharedVaultsTable,
                          VaultItemEntity
                        >(
                          currentTable: table,
                          referencedTable: $$SharedVaultsTableReferences
                              ._vaultItemsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SharedVaultsTableReferences(
                                db,
                                table,
                                p0,
                              ).vaultItemsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.sharedVaultId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (sharedMembersRefs)
                        await $_getPrefetchedData<
                          SharedVaultEntity,
                          $SharedVaultsTable,
                          SharedMemberEntity
                        >(
                          currentTable: table,
                          referencedTable: $$SharedVaultsTableReferences
                              ._sharedMembersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SharedVaultsTableReferences(
                                db,
                                table,
                                p0,
                              ).sharedMembersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.vaultId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$SharedVaultsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SharedVaultsTable,
      SharedVaultEntity,
      $$SharedVaultsTableFilterComposer,
      $$SharedVaultsTableOrderingComposer,
      $$SharedVaultsTableAnnotationComposer,
      $$SharedVaultsTableCreateCompanionBuilder,
      $$SharedVaultsTableUpdateCompanionBuilder,
      (SharedVaultEntity, $$SharedVaultsTableReferences),
      SharedVaultEntity,
      PrefetchHooks Function({bool vaultItemsRefs, bool sharedMembersRefs})
    >;
typedef $$VaultItemsTableCreateCompanionBuilder =
    VaultItemsCompanion Function({
      required String id,
      required int type,
      required String title,
      required String username,
      Value<String?> secret,
      Value<String?> password,
      Value<String?> mnemonic,
      Value<String?> privateKey,
      Value<String?> address,
      Value<String?> network,
      Value<int> period,
      Value<bool> isFavorite,
      Value<String?> url,
      Value<String?> note,
      Value<String?> category,
      Value<String?> email,
      Value<DateTime> updatedAt,
      Value<String?> passwordHistory,
      Value<DateTime?> passwordLastChanged,
      Value<int?> passwordDuration,
      Value<String?> accounts,
      Value<bool> isDeleted,
      Value<DateTime?> deletedAt,
      Value<String?> tags,
      Value<String?> sharedVaultId,
      Value<bool> isPinned,
      Value<String?> colorLabel,
      Value<int> rowid,
    });
typedef $$VaultItemsTableUpdateCompanionBuilder =
    VaultItemsCompanion Function({
      Value<String> id,
      Value<int> type,
      Value<String> title,
      Value<String> username,
      Value<String?> secret,
      Value<String?> password,
      Value<String?> mnemonic,
      Value<String?> privateKey,
      Value<String?> address,
      Value<String?> network,
      Value<int> period,
      Value<bool> isFavorite,
      Value<String?> url,
      Value<String?> note,
      Value<String?> category,
      Value<String?> email,
      Value<DateTime> updatedAt,
      Value<String?> passwordHistory,
      Value<DateTime?> passwordLastChanged,
      Value<int?> passwordDuration,
      Value<String?> accounts,
      Value<bool> isDeleted,
      Value<DateTime?> deletedAt,
      Value<String?> tags,
      Value<String?> sharedVaultId,
      Value<bool> isPinned,
      Value<String?> colorLabel,
      Value<int> rowid,
    });

final class $$VaultItemsTableReferences
    extends BaseReferences<_$AppDatabase, $VaultItemsTable, VaultItemEntity> {
  $$VaultItemsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SharedVaultsTable _sharedVaultIdTable(_$AppDatabase db) =>
      db.sharedVaults.createAlias(
        $_aliasNameGenerator(db.vaultItems.sharedVaultId, db.sharedVaults.id),
      );

  $$SharedVaultsTableProcessedTableManager? get sharedVaultId {
    final $_column = $_itemColumn<String>('shared_vault_id');
    if ($_column == null) return null;
    final manager = $$SharedVaultsTableTableManager(
      $_db,
      $_db.sharedVaults,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_sharedVaultIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$VaultItemsTableFilterComposer
    extends Composer<_$AppDatabase, $VaultItemsTable> {
  $$VaultItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get secret => $composableBuilder(
    column: $table.secret,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mnemonic => $composableBuilder(
    column: $table.mnemonic,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get network => $composableBuilder(
    column: $table.network,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get period => $composableBuilder(
    column: $table.period,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get passwordHistory => $composableBuilder(
    column: $table.passwordHistory,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get passwordLastChanged => $composableBuilder(
    column: $table.passwordLastChanged,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get passwordDuration => $composableBuilder(
    column: $table.passwordDuration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get accounts => $composableBuilder(
    column: $table.accounts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isPinned => $composableBuilder(
    column: $table.isPinned,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get colorLabel => $composableBuilder(
    column: $table.colorLabel,
    builder: (column) => ColumnFilters(column),
  );

  $$SharedVaultsTableFilterComposer get sharedVaultId {
    final $$SharedVaultsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sharedVaultId,
      referencedTable: $db.sharedVaults,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedVaultsTableFilterComposer(
            $db: $db,
            $table: $db.sharedVaults,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$VaultItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $VaultItemsTable> {
  $$VaultItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get username => $composableBuilder(
    column: $table.username,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get secret => $composableBuilder(
    column: $table.secret,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get password => $composableBuilder(
    column: $table.password,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mnemonic => $composableBuilder(
    column: $table.mnemonic,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get address => $composableBuilder(
    column: $table.address,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get network => $composableBuilder(
    column: $table.network,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get period => $composableBuilder(
    column: $table.period,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get url => $composableBuilder(
    column: $table.url,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get category => $composableBuilder(
    column: $table.category,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get email => $composableBuilder(
    column: $table.email,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get passwordHistory => $composableBuilder(
    column: $table.passwordHistory,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get passwordLastChanged => $composableBuilder(
    column: $table.passwordLastChanged,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get passwordDuration => $composableBuilder(
    column: $table.passwordDuration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get accounts => $composableBuilder(
    column: $table.accounts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDeleted => $composableBuilder(
    column: $table.isDeleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tags => $composableBuilder(
    column: $table.tags,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isPinned => $composableBuilder(
    column: $table.isPinned,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get colorLabel => $composableBuilder(
    column: $table.colorLabel,
    builder: (column) => ColumnOrderings(column),
  );

  $$SharedVaultsTableOrderingComposer get sharedVaultId {
    final $$SharedVaultsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sharedVaultId,
      referencedTable: $db.sharedVaults,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedVaultsTableOrderingComposer(
            $db: $db,
            $table: $db.sharedVaults,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$VaultItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $VaultItemsTable> {
  $$VaultItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get username =>
      $composableBuilder(column: $table.username, builder: (column) => column);

  GeneratedColumn<String> get secret =>
      $composableBuilder(column: $table.secret, builder: (column) => column);

  GeneratedColumn<String> get password =>
      $composableBuilder(column: $table.password, builder: (column) => column);

  GeneratedColumn<String> get mnemonic =>
      $composableBuilder(column: $table.mnemonic, builder: (column) => column);

  GeneratedColumn<String> get privateKey => $composableBuilder(
    column: $table.privateKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get network =>
      $composableBuilder(column: $table.network, builder: (column) => column);

  GeneratedColumn<int> get period =>
      $composableBuilder(column: $table.period, builder: (column) => column);

  GeneratedColumn<bool> get isFavorite => $composableBuilder(
    column: $table.isFavorite,
    builder: (column) => column,
  );

  GeneratedColumn<String> get url =>
      $composableBuilder(column: $table.url, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<String> get category =>
      $composableBuilder(column: $table.category, builder: (column) => column);

  GeneratedColumn<String> get email =>
      $composableBuilder(column: $table.email, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get passwordHistory => $composableBuilder(
    column: $table.passwordHistory,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get passwordLastChanged => $composableBuilder(
    column: $table.passwordLastChanged,
    builder: (column) => column,
  );

  GeneratedColumn<int> get passwordDuration => $composableBuilder(
    column: $table.passwordDuration,
    builder: (column) => column,
  );

  GeneratedColumn<String> get accounts =>
      $composableBuilder(column: $table.accounts, builder: (column) => column);

  GeneratedColumn<bool> get isDeleted =>
      $composableBuilder(column: $table.isDeleted, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);

  GeneratedColumn<String> get tags =>
      $composableBuilder(column: $table.tags, builder: (column) => column);

  GeneratedColumn<bool> get isPinned =>
      $composableBuilder(column: $table.isPinned, builder: (column) => column);

  GeneratedColumn<String> get colorLabel => $composableBuilder(
    column: $table.colorLabel,
    builder: (column) => column,
  );

  $$SharedVaultsTableAnnotationComposer get sharedVaultId {
    final $$SharedVaultsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.sharedVaultId,
      referencedTable: $db.sharedVaults,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedVaultsTableAnnotationComposer(
            $db: $db,
            $table: $db.sharedVaults,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$VaultItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $VaultItemsTable,
          VaultItemEntity,
          $$VaultItemsTableFilterComposer,
          $$VaultItemsTableOrderingComposer,
          $$VaultItemsTableAnnotationComposer,
          $$VaultItemsTableCreateCompanionBuilder,
          $$VaultItemsTableUpdateCompanionBuilder,
          (VaultItemEntity, $$VaultItemsTableReferences),
          VaultItemEntity,
          PrefetchHooks Function({bool sharedVaultId})
        > {
  $$VaultItemsTableTableManager(_$AppDatabase db, $VaultItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<int> type = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> username = const Value.absent(),
                Value<String?> secret = const Value.absent(),
                Value<String?> password = const Value.absent(),
                Value<String?> mnemonic = const Value.absent(),
                Value<String?> privateKey = const Value.absent(),
                Value<String?> address = const Value.absent(),
                Value<String?> network = const Value.absent(),
                Value<int> period = const Value.absent(),
                Value<bool> isFavorite = const Value.absent(),
                Value<String?> url = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> email = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String?> passwordHistory = const Value.absent(),
                Value<DateTime?> passwordLastChanged = const Value.absent(),
                Value<int?> passwordDuration = const Value.absent(),
                Value<String?> accounts = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<String?> sharedVaultId = const Value.absent(),
                Value<bool> isPinned = const Value.absent(),
                Value<String?> colorLabel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultItemsCompanion(
                id: id,
                type: type,
                title: title,
                username: username,
                secret: secret,
                password: password,
                mnemonic: mnemonic,
                privateKey: privateKey,
                address: address,
                network: network,
                period: period,
                isFavorite: isFavorite,
                url: url,
                note: note,
                category: category,
                email: email,
                updatedAt: updatedAt,
                passwordHistory: passwordHistory,
                passwordLastChanged: passwordLastChanged,
                passwordDuration: passwordDuration,
                accounts: accounts,
                isDeleted: isDeleted,
                deletedAt: deletedAt,
                tags: tags,
                sharedVaultId: sharedVaultId,
                isPinned: isPinned,
                colorLabel: colorLabel,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required int type,
                required String title,
                required String username,
                Value<String?> secret = const Value.absent(),
                Value<String?> password = const Value.absent(),
                Value<String?> mnemonic = const Value.absent(),
                Value<String?> privateKey = const Value.absent(),
                Value<String?> address = const Value.absent(),
                Value<String?> network = const Value.absent(),
                Value<int> period = const Value.absent(),
                Value<bool> isFavorite = const Value.absent(),
                Value<String?> url = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<String?> category = const Value.absent(),
                Value<String?> email = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String?> passwordHistory = const Value.absent(),
                Value<DateTime?> passwordLastChanged = const Value.absent(),
                Value<int?> passwordDuration = const Value.absent(),
                Value<String?> accounts = const Value.absent(),
                Value<bool> isDeleted = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<String?> tags = const Value.absent(),
                Value<String?> sharedVaultId = const Value.absent(),
                Value<bool> isPinned = const Value.absent(),
                Value<String?> colorLabel = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => VaultItemsCompanion.insert(
                id: id,
                type: type,
                title: title,
                username: username,
                secret: secret,
                password: password,
                mnemonic: mnemonic,
                privateKey: privateKey,
                address: address,
                network: network,
                period: period,
                isFavorite: isFavorite,
                url: url,
                note: note,
                category: category,
                email: email,
                updatedAt: updatedAt,
                passwordHistory: passwordHistory,
                passwordLastChanged: passwordLastChanged,
                passwordDuration: passwordDuration,
                accounts: accounts,
                isDeleted: isDeleted,
                deletedAt: deletedAt,
                tags: tags,
                sharedVaultId: sharedVaultId,
                isPinned: isPinned,
                colorLabel: colorLabel,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$VaultItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({sharedVaultId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (sharedVaultId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.sharedVaultId,
                                referencedTable: $$VaultItemsTableReferences
                                    ._sharedVaultIdTable(db),
                                referencedColumn: $$VaultItemsTableReferences
                                    ._sharedVaultIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$VaultItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $VaultItemsTable,
      VaultItemEntity,
      $$VaultItemsTableFilterComposer,
      $$VaultItemsTableOrderingComposer,
      $$VaultItemsTableAnnotationComposer,
      $$VaultItemsTableCreateCompanionBuilder,
      $$VaultItemsTableUpdateCompanionBuilder,
      (VaultItemEntity, $$VaultItemsTableReferences),
      VaultItemEntity,
      PrefetchHooks Function({bool sharedVaultId})
    >;
typedef $$SharedMembersTableCreateCompanionBuilder =
    SharedMembersCompanion Function({
      required String id,
      required String vaultId,
      required String userPublicKey,
      required String encryptedVaultKey,
      required int role,
      Value<String?> name,
      Value<int> rowid,
    });
typedef $$SharedMembersTableUpdateCompanionBuilder =
    SharedMembersCompanion Function({
      Value<String> id,
      Value<String> vaultId,
      Value<String> userPublicKey,
      Value<String> encryptedVaultKey,
      Value<int> role,
      Value<String?> name,
      Value<int> rowid,
    });

final class $$SharedMembersTableReferences
    extends
        BaseReferences<_$AppDatabase, $SharedMembersTable, SharedMemberEntity> {
  $$SharedMembersTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SharedVaultsTable _vaultIdTable(_$AppDatabase db) =>
      db.sharedVaults.createAlias(
        $_aliasNameGenerator(db.sharedMembers.vaultId, db.sharedVaults.id),
      );

  $$SharedVaultsTableProcessedTableManager get vaultId {
    final $_column = $_itemColumn<String>('vault_id')!;

    final manager = $$SharedVaultsTableTableManager(
      $_db,
      $_db.sharedVaults,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_vaultIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SharedMembersTableFilterComposer
    extends Composer<_$AppDatabase, $SharedMembersTable> {
  $$SharedMembersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userPublicKey => $composableBuilder(
    column: $table.userPublicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get encryptedVaultKey => $composableBuilder(
    column: $table.encryptedVaultKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  $$SharedVaultsTableFilterComposer get vaultId {
    final $$SharedVaultsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.vaultId,
      referencedTable: $db.sharedVaults,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedVaultsTableFilterComposer(
            $db: $db,
            $table: $db.sharedVaults,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SharedMembersTableOrderingComposer
    extends Composer<_$AppDatabase, $SharedMembersTable> {
  $$SharedMembersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userPublicKey => $composableBuilder(
    column: $table.userPublicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get encryptedVaultKey => $composableBuilder(
    column: $table.encryptedVaultKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  $$SharedVaultsTableOrderingComposer get vaultId {
    final $$SharedVaultsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.vaultId,
      referencedTable: $db.sharedVaults,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedVaultsTableOrderingComposer(
            $db: $db,
            $table: $db.sharedVaults,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SharedMembersTableAnnotationComposer
    extends Composer<_$AppDatabase, $SharedMembersTable> {
  $$SharedMembersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get userPublicKey => $composableBuilder(
    column: $table.userPublicKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get encryptedVaultKey => $composableBuilder(
    column: $table.encryptedVaultKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  $$SharedVaultsTableAnnotationComposer get vaultId {
    final $$SharedVaultsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.vaultId,
      referencedTable: $db.sharedVaults,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SharedVaultsTableAnnotationComposer(
            $db: $db,
            $table: $db.sharedVaults,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SharedMembersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SharedMembersTable,
          SharedMemberEntity,
          $$SharedMembersTableFilterComposer,
          $$SharedMembersTableOrderingComposer,
          $$SharedMembersTableAnnotationComposer,
          $$SharedMembersTableCreateCompanionBuilder,
          $$SharedMembersTableUpdateCompanionBuilder,
          (SharedMemberEntity, $$SharedMembersTableReferences),
          SharedMemberEntity,
          PrefetchHooks Function({bool vaultId})
        > {
  $$SharedMembersTableTableManager(_$AppDatabase db, $SharedMembersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SharedMembersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SharedMembersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SharedMembersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> vaultId = const Value.absent(),
                Value<String> userPublicKey = const Value.absent(),
                Value<String> encryptedVaultKey = const Value.absent(),
                Value<int> role = const Value.absent(),
                Value<String?> name = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SharedMembersCompanion(
                id: id,
                vaultId: vaultId,
                userPublicKey: userPublicKey,
                encryptedVaultKey: encryptedVaultKey,
                role: role,
                name: name,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String vaultId,
                required String userPublicKey,
                required String encryptedVaultKey,
                required int role,
                Value<String?> name = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SharedMembersCompanion.insert(
                id: id,
                vaultId: vaultId,
                userPublicKey: userPublicKey,
                encryptedVaultKey: encryptedVaultKey,
                role: role,
                name: name,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SharedMembersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({vaultId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (vaultId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.vaultId,
                                referencedTable: $$SharedMembersTableReferences
                                    ._vaultIdTable(db),
                                referencedColumn: $$SharedMembersTableReferences
                                    ._vaultIdTable(db)
                                    .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SharedMembersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SharedMembersTable,
      SharedMemberEntity,
      $$SharedMembersTableFilterComposer,
      $$SharedMembersTableOrderingComposer,
      $$SharedMembersTableAnnotationComposer,
      $$SharedMembersTableCreateCompanionBuilder,
      $$SharedMembersTableUpdateCompanionBuilder,
      (SharedMemberEntity, $$SharedMembersTableReferences),
      SharedMemberEntity,
      PrefetchHooks Function({bool vaultId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SharedVaultsTableTableManager get sharedVaults =>
      $$SharedVaultsTableTableManager(_db, _db.sharedVaults);
  $$VaultItemsTableTableManager get vaultItems =>
      $$VaultItemsTableTableManager(_db, _db.vaultItems);
  $$SharedMembersTableTableManager get sharedMembers =>
      $$SharedMembersTableTableManager(_db, _db.sharedMembers);
}
