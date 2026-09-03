class WebDavConfig {
  final String url;
  final String username;
  final String password;
  final String backupDirectory;

  WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
    this.backupDirectory = 'password_backup',
  });

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'username': username,
      'password': password,
      'backupDirectory': backupDirectory,
    };
  }

  factory WebDavConfig.fromJson(Map<String, dynamic> json) {
    return WebDavConfig(
      url: json['url'] ?? '',
      username: json['username'] ?? '',
      password: json['password'] ?? '',
      backupDirectory: json['backupDirectory'] ?? 'password_backup',
    );
  }

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? backupDirectory,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      backupDirectory: backupDirectory ?? this.backupDirectory,
    );
  }

  bool get isValid =>
      url.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
}
