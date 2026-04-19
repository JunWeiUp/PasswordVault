class FaviconUtils {
  /// 从条目 URL（可含多个域名）中取出第一个主机名，用作 favicon / 缓存键。
  static String extractDomain(String? url) {
    if (url == null || url.isEmpty) return '';

    final rawSegment = url
        .split(RegExp(r'[,\n;]'))
        .map((u) => u.trim())
        .firstWhere((u) => u.isNotEmpty, orElse: () => '');

    if (rawSegment.isEmpty) return '';

    try {
      final normalized =
          rawSegment.contains('://') ? rawSegment : 'https://$rawSegment';
      final uri = Uri.parse(normalized);
      final host = uri.host.toLowerCase();
      if (host.isNotEmpty) return host;
    } catch (_) {}

    final fallback = rawSegment.split('/').first.split(':').first.trim().toLowerCase();
    return fallback;
  }

  /// 获取网站图标的 URL
  /// 使用 Google 的 Favicon 服务，因为它比较稳定且支持多种尺寸
  static String getFaviconUrl(String? url) {
    final domain = extractDomain(url);
    if (domain.isEmpty) return '';

    // sz=64 表示请求 64x64 的图标
    return 'https://www.google.com/s2/favicons?domain=$domain&sz=64';
  }
}
