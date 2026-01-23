import 'package:flutter/material.dart';
import '../../../../core/utils/favicon_utils.dart';

class FaviconWidget extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final faviconUrl = FaviconUtils.getFaviconUrl(url);

    if (faviconUrl.isEmpty) {
      return _buildFallback();
    }

    return Image.network(
      faviconUrl,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return _buildFallback();
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return SizedBox(
          width: size,
          height: size,
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
    final firstLetter = title.isNotEmpty ? title[0].toUpperCase() : '?';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade100,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        firstLetter,
        style: TextStyle(
          fontSize: size * 0.6,
          fontWeight: FontWeight.bold,
          color: Colors.blueGrey.shade700,
        ),
      ),
    );
  }
}
