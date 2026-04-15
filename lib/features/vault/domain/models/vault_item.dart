enum VaultItemType { password, totp, crypto, secureNote }

class VaultItem {
  final String id;
  final VaultItemType type;
  final String title;
  final String username;
  final String? secret;   // 用于 TOTP 的密钥
  final String? password; // 用于账号密码的密码
  final String? mnemonic; // 用于加密货币的助记词
  final String? privateKey; // 用于加密货币的私钥
  final String? address;  // 用于加密货币的钱包地址
  final String? network;  // 用于加密货币的网络 (如 BTC, ETH, SOL)
  final int period;
  final bool isFavorite;
  final String? url;      // 网站链接
  final String? note;     // 备注
  final String? category; // 分类
  final String? email;    // 邮箱
  final bool isDeleted;   // 是否已删除（回收站）
  final DateTime? deletedAt; // 删除时间
  final List<PasswordHistoryEntry>? passwordHistory;
  final List<AccountEntry>? accounts;
  final DateTime? passwordLastChanged;
  final int? passwordDuration; // Days
  final List<String> tags;
  final DateTime? updatedAt;
  final String? sharedVaultId;
  final bool isPinned;
  final String? colorLabel;

  VaultItem({
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
    this.period = 30,
    this.isFavorite = false,
    this.url,
    this.note,
    this.category,
    this.email,
    this.isDeleted = false,
    this.deletedAt,
    this.passwordHistory,
    this.accounts,
    this.passwordLastChanged,
    this.passwordDuration,
    this.tags = const [],
    this.updatedAt,
    this.sharedVaultId,
    this.isPinned = false,
    this.colorLabel,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'title': title,
      'username': username,
      'secret': secret,
      'password': password,
      'mnemonic': mnemonic,
      'privateKey': privateKey,
      'address': address,
      'network': network,
      'period': period,
      'isFavorite': isFavorite,
      'url': url,
      'note': note,
      'category': category,
      'email': email,
      'isDeleted': isDeleted,
      'deletedAt': deletedAt?.toIso8601String(),
      'passwordHistory': passwordHistory?.map((e) => e.toJson()).toList(),
      'accounts': accounts?.map((e) => e.toJson()).toList(),
      'passwordLastChanged': passwordLastChanged?.toIso8601String(),
      'passwordDuration': passwordDuration,
      'tags': tags,
      'updatedAt': updatedAt?.toIso8601String(),
      'sharedVaultId': sharedVaultId,
      'isPinned': isPinned,
      'colorLabel': colorLabel,
    };
  }

  factory VaultItem.fromJson(Map<String, dynamic> json) {
    VaultItemType type;
    try {
      type = VaultItemType.values.byName(json['type'] as String);
    } catch (e) {
      type = VaultItemType.password;
    }

    return VaultItem(
      id: json['id']?.toString() ?? '',
      type: type,
      title: json['title']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      secret: json['secret']?.toString(),
      password: json['password']?.toString(),
      mnemonic: json['mnemonic']?.toString(),
      privateKey: json['privateKey']?.toString(),
      address: json['address']?.toString(),
      network: json['network']?.toString(),
      period: json['period'] as int? ?? 30,
      isFavorite: json['isFavorite'] as bool? ?? false,
      url: json['url']?.toString(),
      note: json['note']?.toString(),
      category: json['category']?.toString(),
      email: json['email']?.toString(),
      isDeleted: json['isDeleted'] as bool? ?? false,
      deletedAt: json['deletedAt'] != null ? DateTime.tryParse(json['deletedAt'].toString()) : null,
      passwordHistory: (json['passwordHistory'] as List?)
          ?.map((e) => PasswordHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      accounts: (json['accounts'] as List?)
          ?.map((e) => AccountEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      passwordLastChanged: json['passwordLastChanged'] != null ? DateTime.tryParse(json['passwordLastChanged'].toString()) : null,
      passwordDuration: json['passwordDuration'] as int?,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ?? [],
      updatedAt: json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'].toString()) : null,
      sharedVaultId: json['sharedVaultId']?.toString(),
      isPinned: json['isPinned'] as bool? ?? false,
      colorLabel: json['colorLabel']?.toString(),
    );
  }

  VaultItem copyWith({
    String? id,
    VaultItemType? type,
    String? title,
    String? username,
    String? secret,
    String? password,
    String? mnemonic,
    String? privateKey,
    String? address,
    String? network,
    int? period,
    bool? isFavorite,
    String? url,
    String? note,
    String? category,
    String? email,
    bool? isDeleted,
    DateTime? deletedAt,
    List<PasswordHistoryEntry>? passwordHistory,
    List<AccountEntry>? accounts,
    DateTime? passwordLastChanged,
    int? passwordDuration,
    List<String>? tags,
    DateTime? updatedAt,
    String? sharedVaultId,
    bool? isPinned,
    String? colorLabel,
  }) {
    return VaultItem(
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
      isDeleted: isDeleted ?? this.isDeleted,
      deletedAt: deletedAt ?? this.deletedAt,
      passwordHistory: passwordHistory ?? this.passwordHistory,
      accounts: accounts ?? this.accounts,
      passwordLastChanged: passwordLastChanged ?? this.passwordLastChanged,
      passwordDuration: passwordDuration ?? this.passwordDuration,
      tags: tags ?? this.tags,
      updatedAt: updatedAt ?? this.updatedAt,
      sharedVaultId: sharedVaultId ?? this.sharedVaultId,
      isPinned: isPinned ?? this.isPinned,
      colorLabel: colorLabel ?? this.colorLabel,
    );
  }
}

enum SharedMemberRole { viewer, editor, owner }

class SharedVault {
  final String id;
  final String name;
  final String encryptedVaultKey; // 对当前用户加密后的 VaultKey (Base64)
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDiscoverable; // 是否在局域网内可发现

  SharedVault({
    required this.id,
    required this.name,
    required this.encryptedVaultKey,
    required this.createdAt,
    required this.updatedAt,
    this.isDiscoverable = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'encryptedVaultKey': encryptedVaultKey,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isDiscoverable': isDiscoverable,
    };
  }

  factory SharedVault.fromJson(Map<String, dynamic> json) {
    return SharedVault(
      id: json['id'] as String,
      name: json['name'] as String,
      encryptedVaultKey: json['encryptedVaultKey'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      isDiscoverable: json['isDiscoverable'] as bool? ?? false,
    );
  }

  SharedVault copyWith({
    String? id,
    String? name,
    String? encryptedVaultKey,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDiscoverable,
  }) {
    return SharedVault(
      id: id ?? this.id,
      name: name ?? this.name,
      encryptedVaultKey: encryptedVaultKey ?? this.encryptedVaultKey,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDiscoverable: isDiscoverable ?? this.isDiscoverable,
    );
  }
}

class SharedMember {
  final String id;
  final String vaultId;
  final String userPublicKey; // 成员的公钥 (Base64)
  final String encryptedVaultKey; // 对该成员加密后的 VaultKey (Base64)
  final SharedMemberRole role;
  final String? name; // 成员备注名

  SharedMember({
    required this.id,
    required this.vaultId,
    required this.userPublicKey,
    required this.encryptedVaultKey,
    required this.role,
    this.name,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'vaultId': vaultId,
      'userPublicKey': userPublicKey,
      'encryptedVaultKey': encryptedVaultKey,
      'role': role.name,
      'name': name,
    };
  }

  factory SharedMember.fromJson(Map<String, dynamic> json) {
    return SharedMember(
      id: json['id'] as String,
      vaultId: json['vaultId'] as String,
      userPublicKey: json['userPublicKey'] as String,
      encryptedVaultKey: json['encryptedVaultKey'] as String,
      role: SharedMemberRole.values.byName(json['role'] as String),
      name: json['name'] as String?,
    );
  }
}

class AccountEntry {
  final String id;
  final String username;
  final String password;
  final String? label;
  final List<PasswordHistoryEntry>? passwordHistory;
  final DateTime? passwordLastChanged;

  AccountEntry({
    required this.id,
    required this.username,
    required this.password,
    this.label,
    this.passwordHistory,
    this.passwordLastChanged,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'password': password,
      'label': label,
      'passwordHistory': passwordHistory?.map((e) => e.toJson()).toList(),
      'passwordLastChanged': passwordLastChanged?.toIso8601String(),
    };
  }

  factory AccountEntry.fromJson(Map<String, dynamic> json) {
    return AccountEntry(
      id: json['id']?.toString() ?? '',
      username: json['username']?.toString() ?? '',
      password: json['password']?.toString() ?? '',
      label: json['label']?.toString(),
      passwordHistory: (json['passwordHistory'] as List?)
          ?.map((e) => PasswordHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      passwordLastChanged: json['passwordLastChanged'] != null
          ? DateTime.tryParse(json['passwordLastChanged'].toString())
          : null,
    );
  }
}

class PasswordHistoryEntry {
  final String password;
  final DateTime changedAt;

  PasswordHistoryEntry({
    required this.password,
    required this.changedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'password': password,
      'changedAt': changedAt.toIso8601String(),
    };
  }

  factory PasswordHistoryEntry.fromJson(Map<String, dynamic> json) {
    return PasswordHistoryEntry(
      password: json['password'] as String,
      changedAt: DateTime.parse(json['changedAt'] as String),
    );
  }
}
