import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/extension/extension_helper.dart';
import '../../../../core/utils/favicon_cache_service.dart';
import '../../../../core/utils/favicon_utils.dart';

class FaviconWidget extends StatefulWidget {
  final String? url;
  final String title;
  final double size;

  const FaviconWidget({
    super.key,
    required this.url,
    required this.title,
    this.size = 24.0,
  });

  @override
  State<FaviconWidget> createState() => _FaviconWidgetState();
}

class _FaviconWidgetState extends State<FaviconWidget> {
  Uint8List? _cachedBytes;
  bool _extensionResolved = false;

  @override
  void initState() {
    super.initState();
    if (ExtensionHelper.isExtension) {
      _loadCachedFavicon();
    } else {
      _extensionResolved = true;
    }
  }

  @override
  void didUpdateWidget(FaviconWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (ExtensionHelper.isExtension && oldWidget.url != widget.url) {
      _cachedBytes = null;
      _extensionResolved = false;
      _loadCachedFavicon();
    }
  }

  Future<void> _loadCachedFavicon() async {
    final bytes = await FaviconCacheService.instance.loadOrFetch(widget.url);
    if (!mounted) return;
    setState(() {
      _cachedBytes = bytes;
      _extensionResolved = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!ExtensionHelper.isExtension) {
      return _buildNetworkFavicon();
    }

    // 加载前先显示首字母占位，避免列表页大量加载指示器
    if (!_extensionResolved) {
      return _buildFallback();
    }

    if (_cachedBytes != null && _cachedBytes!.isNotEmpty) {
      return Image.memory(
        _cachedBytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) => _buildFallback(),
      );
    }

    return _buildFallback();
  }

  Widget _buildNetworkFavicon() {
    final faviconUrl = FaviconUtils.getFaviconUrl(widget.url);

    if (faviconUrl.isEmpty) {
      return _buildFallback();
    }

    return Image.network(
      faviconUrl,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return _buildFallback();
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded /
                      loadingProgress.expectedTotalBytes!
                  : null,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallback() {
    final firstLetter = widget.title.isNotEmpty ? widget.title[0].toUpperCase() : '?';
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade100,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        firstLetter,
        style: TextStyle(
          fontSize: widget.size * 0.6,
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey.shade700,
        ),
      ),
    );
  }
}
