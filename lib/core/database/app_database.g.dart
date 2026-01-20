// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $VaultItemsTable extends VaultItems
    with TableInfo<$VaultItemsTable, VaultItemEntity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $VaultItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<int> type = GeneratedColumn<int>(
      'type', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _usernameMeta =
      const VerificationMeta('username');
  @override
  late final GeneratedColumn<String> username = GeneratedColumn<String>(
      'username', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _secretMeta = const VerificationMeta('secret');
  @override
  late final GeneratedColumn<String> secret = GeneratedColumn<String>(
      'secret', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _passwordMeta =
      const VerificationMeta('password');
  @override
  late final GeneratedColumn<String> password = GeneratedColumn<String>(
      'password', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _mnemonicMeta =
      const VerificationMeta('mnemonic');
  @override
  late final GeneratedColumn<String> mnemonic = GeneratedColumn<String>(
      'mnemonic', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _privateKeyMeta =
      const VerificationMeta('privateKey');
  @override
  late final GeneratedColumn<String> privateKey = GeneratedColumn<String>(
      'private_key', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _addressMeta =
      const VerificationMeta('address');
  @override
  late final GeneratedColumn<String> address = GeneratedColumn<String>(
      'address', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _networkMeta =
      const VerificationMeta('network');
  @override
  late final GeneratedColumn<String> network = GeneratedColumn<String>(
      'network', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _periodMeta = const VerificationMeta('period');
  @override
  late final GeneratedColumn<int> period = GeneratedColumn<int>(
      'period', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(30));
  static const VerificationMeta _isFavoriteMeta =
      const VerificationMeta('isFavorite');
  @override
  late final GeneratedColumn<bool> isFavorite = GeneratedColumn<bool>(
      'is_favorite', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("is_favorite" IN (0, 1))'),
      defaultValue: const Constant(false));
  static const VerificationMeta _urlMeta = const VerificationMeta('url');
  @override
  late final GeneratedColumn<String> url = GeneratedColumn<String>(
      'url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
      'note', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _categoryMeta =
      const VerificationMeta('category');
  @override
  late final GeneratedColumn<String> category = GeneratedColumn<String>(
      'category', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _emailMeta = const VerificationMeta('email');
  @override
  late final GeneratedColumn<String> email = GeneratedColumn<String>(
      'email', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime,
      requiredDuringInsert: false,
      defaultValue: currentDateAndTime);
  static const VerificationMeta _passwordHistoryMeta =
      const VerificationMeta('passwordHistory');
  @override
  late final GeneratedColumn<String> passwordHistory = GeneratedColumn<String>(
      'password_history', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _passwordLastChangedMeta =
      const VerificationMeta('passwordLastChanged');
  @override
  late final GeneratedColumn<DateTime> passwordLastChanged =
      GeneratedColumn<DateTime>('password_last_changed', aliasedName, true,
          type: DriftSqlType.dateTime, requiredDuringInsert: false);
  static const VerificationMeta _passwordDurationMeta =
      const VerificationMeta('passwordDuration');
  @override
  late final GeneratedColumn<int> passwordDuration = GeneratedColumn<int>(
      'password_duration', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
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
        passwordDuration
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'vault_items';
  @override
  VerificationContext validateIntegrity(Insertable<VaultItemEntity> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
          _typeMeta, type.isAcceptableOrUnknown(data['type']!, _typeMeta));
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('username')) {
      context.handle(_usernameMeta,
          username.isAcceptableOrUnknown(data['username']!, _usernameMeta));
    } else if (isInserting) {
      context.missing(_usernameMeta);
    }
    if (data.containsKey('secret')) {
      context.handle(_secretMeta,
          secret.isAcceptableOrUnknown(data['secret']!, _secretMeta));
    }
    if (data.containsKey('password')) {
      context.handle(_passwordMeta,
          password.isAcceptableOrUnknown(data['password']!, _passwordMeta));
    }
    if (data.containsKey('mnemonic')) {
      context.handle(_mnemonicMeta,
          mnemonic.isAcceptableOrUnknown(data['mnemonic']!, _mnemonicMeta));
    }
    if (data.containsKey('private_key')) {
      context.handle(
          _privateKeyMeta,
          privateKey.isAcceptableOrUnknown(
              data['private_key']!, _privateKeyMeta));
    }
    if (data.containsKey('address')) {
      context.handle(_addressMeta,
          address.isAcceptableOrUnknown(data['address']!, _addressMeta));
    }
    if (data.containsKey('network')) {
      context.handle(_networkMeta,
          network.isAcceptableOrUnknown(data['network']!, _networkMeta));
    }
    if (data.containsKey('period')) {
      context.handle(_periodMeta,
          period.isAcceptableOrUnknown(data['period']!, _periodMeta));
    }
    if (data.containsKey('is_favorite')) {
      context.handle(
          _isFavoriteMeta,
          isFavorite.isAcceptableOrUnknown(
              data['is_favorite']!, _isFavoriteMeta));
    }
    if (data.containsKey('url')) {
      context.handle(
          _urlMeta, url.isAcceptableOrUnknown(data['url']!, _urlMeta));
    }
    if (data.containsKey('note')) {
      context.handle(
          _noteMeta, note.isAcceptableOrUnknown(data['note']!, _noteMeta));
    }
    if (data.containsKey('category')) {
      context.handle(_categoryMeta,
          category.isAcceptableOrUnknown(data['category']!, _categoryMeta));
    }
    if (data.containsKey('email')) {
      context.handle(
          _emailMeta, email.isAcceptableOrUnknown(data['email']!, _emailMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('password_history')) {
      context.handle(
          _passwordHistoryMeta,
          passwordHistory.isAcceptableOrUnknown(
              data['password_history']!, _passwordHistoryMeta));
    }
    if (data.containsKey('password_last_changed')) {
      context.handle(
          _passwordLastChangedMeta,
          passwordLastChanged.isAcceptableOrUnknown(
              data['password_last_changed']!, _passwordLastChangedMeta));
    }
    if (data.containsKey('password_duration')) {
      context.handle(
          _passwordDurationMeta,
          passwordDuration.isAcceptableOrUnknown(
              data['password_duration']!, _passwordDurationMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  VaultItemEntity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return VaultItemEntity(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      type: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}type'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      username: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}username'])!,
      secret: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}secret']),
      password: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}password']),
      mnemonic: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}mnemonic']),
      privateKey: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}private_key']),
      address: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}address']),
      network: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}network']),
      period: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}period'])!,
      isFavorite: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}is_favorite'])!,
      url: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}url']),
      note: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}note']),
      category: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}category']),
      email: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}email']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
      passwordHistory: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}password_history']),
      passwordLastChanged: attachedDatabase.typeMapping.read(
          DriftSqlType.dateTime,
          data['${effectivePrefix}password_last_changed']),
      passwordDuration: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}password_duration']),
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
  const VaultItemEntity(
      {required this.id,
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
      this.passwordDuration});
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
    return map;
  }

  VaultItemsCompanion toCompanion(bool nullToAbsent) {
    return VaultItemsCompanion(
      id: Value(id),
      type: Value(type),
      title: Value(title),
      username: Value(username),
      secret:
          secret == null && nullToAbsent ? const Value.absent() : Value(secret),
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
      email:
          email == null && nullToAbsent ? const Value.absent() : Value(email),
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
    );
  }

  factory VaultItemEntity.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
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
      passwordLastChanged:
          serializer.fromJson<DateTime?>(json['passwordLastChanged']),
      passwordDuration: serializer.fromJson<int?>(json['passwordDuration']),
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
    };
  }

  VaultItemEntity copyWith(
          {String? id,
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
          Value<int?> passwordDuration = const Value.absent()}) =>
      VaultItemEntity(
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
      privateKey:
          data.privateKey.present ? data.privateKey.value : this.privateKey,
      address: data.address.present ? data.address.value : this.address,
      network: data.network.present ? data.network.value : this.network,
      period: data.period.present ? data.period.value : this.period,
      isFavorite:
          data.isFavorite.present ? data.isFavorite.value : this.isFavorite,
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
          ..write('passwordDuration: $passwordDuration')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
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
      passwordDuration);
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
          other.passwordDuration == this.passwordDuration);
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
    this.rowid = const Value.absent(),
  })  : id = Value(id),
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
      if (rowid != null) 'rowid': rowid,
    });
  }

  VaultItemsCompanion copyWith(
      {Value<String>? id,
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
      Value<int>? rowid}) {
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
      map['password_last_changed'] =
          Variable<DateTime>(passwordLastChanged.value);
    }
    if (passwordDuration.present) {
      map['password_duration'] = Variable<int>(passwordDuration.value);
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
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $VaultItemsTable vaultItems = $VaultItemsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [vaultItems];
}

typedef $$VaultItemsTableCreateCompanionBuilder = VaultItemsCompanion Function({
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
  Value<int> rowid,
});
typedef $$VaultItemsTableUpdateCompanionBuilder = VaultItemsCompanion Function({
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
  Value<int> rowid,
});

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
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get username => $composableBuilder(
      column: $table.username, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get secret => $composableBuilder(
      column: $table.secret, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get password => $composableBuilder(
      column: $table.password, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mnemonic => $composableBuilder(
      column: $table.mnemonic, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get privateKey => $composableBuilder(
      column: $table.privateKey, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get address => $composableBuilder(
      column: $table.address, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get network => $composableBuilder(
      column: $table.network, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get period => $composableBuilder(
      column: $table.period, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get isFavorite => $composableBuilder(
      column: $table.isFavorite, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get email => $composableBuilder(
      column: $table.email, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get passwordHistory => $composableBuilder(
      column: $table.passwordHistory,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get passwordLastChanged => $composableBuilder(
      column: $table.passwordLastChanged,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get passwordDuration => $composableBuilder(
      column: $table.passwordDuration,
      builder: (column) => ColumnFilters(column));
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
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get type => $composableBuilder(
      column: $table.type, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get username => $composableBuilder(
      column: $table.username, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get secret => $composableBuilder(
      column: $table.secret, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get password => $composableBuilder(
      column: $table.password, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mnemonic => $composableBuilder(
      column: $table.mnemonic, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get privateKey => $composableBuilder(
      column: $table.privateKey, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get address => $composableBuilder(
      column: $table.address, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get network => $composableBuilder(
      column: $table.network, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get period => $composableBuilder(
      column: $table.period, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get isFavorite => $composableBuilder(
      column: $table.isFavorite, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get url => $composableBuilder(
      column: $table.url, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get note => $composableBuilder(
      column: $table.note, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get category => $composableBuilder(
      column: $table.category, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get email => $composableBuilder(
      column: $table.email, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get passwordHistory => $composableBuilder(
      column: $table.passwordHistory,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get passwordLastChanged => $composableBuilder(
      column: $table.passwordLastChanged,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get passwordDuration => $composableBuilder(
      column: $table.passwordDuration,
      builder: (column) => ColumnOrderings(column));
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
      column: $table.privateKey, builder: (column) => column);

  GeneratedColumn<String> get address =>
      $composableBuilder(column: $table.address, builder: (column) => column);

  GeneratedColumn<String> get network =>
      $composableBuilder(column: $table.network, builder: (column) => column);

  GeneratedColumn<int> get period =>
      $composableBuilder(column: $table.period, builder: (column) => column);

  GeneratedColumn<bool> get isFavorite => $composableBuilder(
      column: $table.isFavorite, builder: (column) => column);

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
      column: $table.passwordHistory, builder: (column) => column);

  GeneratedColumn<DateTime> get passwordLastChanged => $composableBuilder(
      column: $table.passwordLastChanged, builder: (column) => column);

  GeneratedColumn<int> get passwordDuration => $composableBuilder(
      column: $table.passwordDuration, builder: (column) => column);
}

class $$VaultItemsTableTableManager extends RootTableManager<
    _$AppDatabase,
    $VaultItemsTable,
    VaultItemEntity,
    $$VaultItemsTableFilterComposer,
    $$VaultItemsTableOrderingComposer,
    $$VaultItemsTableAnnotationComposer,
    $$VaultItemsTableCreateCompanionBuilder,
    $$VaultItemsTableUpdateCompanionBuilder,
    (
      VaultItemEntity,
      BaseReferences<_$AppDatabase, $VaultItemsTable, VaultItemEntity>
    ),
    VaultItemEntity,
    PrefetchHooks Function()> {
  $$VaultItemsTableTableManager(_$AppDatabase db, $VaultItemsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$VaultItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$VaultItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$VaultItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
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
            Value<int> rowid = const Value.absent(),
          }) =>
              VaultItemsCompanion(
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
            rowid: rowid,
          ),
          createCompanionCallback: ({
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
            Value<int> rowid = const Value.absent(),
          }) =>
              VaultItemsCompanion.insert(
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
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$VaultItemsTableProcessedTableManager = ProcessedTableManager<
    _$AppDatabase,
    $VaultItemsTable,
    VaultItemEntity,
    $$VaultItemsTableFilterComposer,
    $$VaultItemsTableOrderingComposer,
    $$VaultItemsTableAnnotationComposer,
    $$VaultItemsTableCreateCompanionBuilder,
    $$VaultItemsTableUpdateCompanionBuilder,
    (
      VaultItemEntity,
      BaseReferences<_$AppDatabase, $VaultItemsTable, VaultItemEntity>
    ),
    VaultItemEntity,
    PrefetchHooks Function()>;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$VaultItemsTableTableManager get vaultItems =>
      $$VaultItemsTableTableManager(_db, _db.vaultItems);
}
