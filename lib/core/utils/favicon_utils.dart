class FaviconUtils {
  /// 获取网站图标的 URL
  /// 使用 Google 的 Favicon 服务，因为它比较稳定且支持多种尺寸
  static String getFaviconUrl(String? url) {
    if (url == null || url.isEmpty) return '';
    
    try {
      final uri = Uri.parse(url);
      final domain = uri.host;
      if (domain.isEmpty) return '';
      
      // sz=64 表示请求 64x64 的图标
      return 'https://www.google.com/s2/favicons?domain=$domain&sz=64';
    } catch (e) {
      // 如果 URL 解析失败，尝试直接使用字符串作为域名
      final cleanUrl = url.trim().toLowerCase();
      if (cleanUrl.startsWith('http')) {
        return 'https://www.google.com/s2/favicons?domain=$cleanUrl&sz=64';
      }
      return 'https://www.google.com/s2/favicons?domain=$cleanUrl&sz=64';
    }
  }
}
