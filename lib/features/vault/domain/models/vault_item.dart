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
    };
  }

  factory VaultItem.fromJson(Map<String, dynamic> json) {
    return VaultItem(
      id: json['id'] as String,
      type: VaultItemType.values.byName(json['type'] as String),
      title: json['title'] as String,
      username: json['username'] as String,
      secret: json['secret'] as String?,
      password: json['password'] as String?,
      mnemonic: json['mnemonic'] as String?,
      privateKey: json['privateKey'] as String?,
      address: json['address'] as String?,
      network: json['network'] as String?,
      period: json['period'] as int? ?? 30,
      isFavorite: json['isFavorite'] as bool? ?? false,
      url: json['url'] as String?,
      note: json['note'] as String?,
      category: json['category'] as String?,
      email: json['email'] as String?,
      isDeleted: json['isDeleted'] as bool? ?? false,
      deletedAt: json['deletedAt'] != null ? DateTime.parse(json['deletedAt'] as String) : null,
      passwordHistory: (json['passwordHistory'] as List?)
          ?.map((e) => PasswordHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      accounts: (json['accounts'] as List?)
          ?.map((e) => AccountEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      passwordLastChanged: json['passwordLastChanged'] != null
          ? DateTime.parse(json['passwordLastChanged'] as String)
          : null,
      passwordDuration: json['passwordDuration'] as int?,
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
      id: json['id'] as String? ?? '', // 兼容旧数据
      username: json['username'] as String,
      password: json['password'] as String,
      label: json['label'] as String?,
      passwordHistory: (json['passwordHistory'] as List?)
          ?.map((e) => PasswordHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      passwordLastChanged: json['passwordLastChanged'] != null
          ? DateTime.parse(json['passwordLastChanged'] as String)
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
