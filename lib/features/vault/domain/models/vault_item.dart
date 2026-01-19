enum VaultItemType { password, totp, crypto }

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
    );
  }
}
