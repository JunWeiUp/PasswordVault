import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../extension/extension_helper.dart';
import 'favicon_utils.dart';

/// 浏览器扩展内将站点 favicon 缓存到本地（SharedPreferences / localStorage）。
class FaviconCacheService {
  FaviconCacheService._();
  static final FaviconCacheService instance = FaviconCacheService._();

  static const _keyPrefix = 'sp_favicon_b64_v1_';

  /// 同一域名并发请求合并为一次网络下载。
  final Map<String, Future<Uint8List?>> _inflight = {};

  String _storageKey(String domain) => '$_keyPrefix$domain';

  Future<Uint8List?> read(String domain) async {
    if (domain.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final b64 = prefs.getString(_storageKey(domain));
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String domain, Uint8List bytes) async {
    if (domain.isEmpty || bytes.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey(domain), base64Encode(bytes));
  }

  /// 先读本地缓存；未命中则请求网络并写入缓存。
  Future<Uint8List?> loadOrFetch(String? url) async {
    if (!ExtensionHelper.isExtension) return null;

    final domain = FaviconUtils.extractDomain(url);
    if (domain.isEmpty) return null;

    final cached = await read(domain);
    if (cached != null && cached.isNotEmpty) return cached;

    final existing = _inflight[domain];
    if (existing != null) return existing;

    final future = _downloadAndStore(domain, url);
    _inflight[domain] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(domain);
    }
  }

  Future<Uint8List?> _downloadAndStore(String domain, String? originalUrl) async {
    final faviconUrl = FaviconUtils.getFaviconUrl(originalUrl);
    if (faviconUrl.isEmpty) return null;

    try {
      final response = await http.get(Uri.parse(faviconUrl));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return null;
      await write(domain, response.bodyBytes);
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// 扩展同步账号后批量预取图标（已有缓存则跳过）。
  Future<void> prefetchDomains(Set<String> domains) async {
    if (!ExtensionHelper.isExtension || domains.isEmpty) return;

    const batchSize = 5;
    final list = domains.toList();
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      await Future.wait(
        batch.map((domain) async {
          final d = domain.trim().toLowerCase();
          if (d.isEmpty) return;
          final cached = await read(d);
          if (cached != null && cached.isNotEmpty) return;
          await loadOrFetch('https://$d/');
        }),
      );
    }
  }
}
