// Export the approved brand artwork at each platform's required dimensions.
// Run from the repository root with: dart run tool/generate_icons.dart
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  final root = File.fromUri(Platform.script).parent.parent;
  final sourceFile = File(
    '${root.path}/assets/branding/passwordvault-icon-source.png',
  );
  final source = img.decodePng(sourceFile.readAsBytesSync());
  if (source == null || source.width != source.height) {
    throw StateError('The brand source must be a square PNG.');
  }
  final corner = source.getPixel(0, 0);
  final background = img.ColorRgb8(
    corner.r.toInt(),
    corner.g.toInt(),
    corner.b.toInt(),
  );
  final backgroundHex = [
    corner.r,
    corner.g,
    corner.b,
  ].map((value) => value.toInt().toRadixString(16).padLeft(2, '0')).join();
  final encoded = <int, List<int>>{};
  var count = 0;

  void save(String path, List<int> bytes) {
    final file = File('${root.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    count++;
  }

  void export(String path, int size) {
    final bytes = encoded.putIfAbsent(size, () {
      // RGB output also satisfies iOS's opaque app-icon requirement.
      final output = img.Image(width: size, height: size, numChannels: 3);
      img.fill(output, color: background);
      img.compositeImage(
        output,
        img.copyResize(
          source,
          width: size,
          height: size,
          interpolation: img.Interpolation.average,
        ),
      );
      return img.encodePng(output, level: 9);
    });
    save(path, bytes);
  }

  for (final size in [16, 32, 48, 128, 192, 512]) {
    export('chrome/icons/icon$size.png', size);
  }
  export('assets/branding/passwordvault-icon-512.png', 512);
  export('web/favicon.png', 32);
  for (final size in [192, 512]) {
    export('web/icons/Icon-$size.png', size);
    export('web/icons/Icon-maskable-$size.png', size);
  }

  const densities = {
    'mdpi': 1.0,
    'hdpi': 1.5,
    'xhdpi': 2.0,
    'xxhdpi': 3.0,
    'xxxhdpi': 4.0,
  };
  for (final entry in densities.entries) {
    final folder = 'android/app/src/main/res/mipmap-${entry.key}';
    export('$folder/ic_launcher.png', (48 * entry.value).round());
    final size = (108 * entry.value).round();
    final inset = (size * 0.125).round();
    final foreground = img.Image(width: size, height: size, numChannels: 4);
    img.compositeImage(
      foreground,
      img.copyResize(
        source,
        width: size - 2 * inset,
        height: size - 2 * inset,
        interpolation: img.Interpolation.average,
      ),
      dstX: inset,
      dstY: inset,
    );
    save(
      '$folder/ic_launcher_foreground.png',
      img.encodePng(foreground, level: 9),
    );
  }

  final colorFile = File(
    '${root.path}/android/app/src/main/res/values/icon_colors.xml',
  );
  colorFile.writeAsStringSync(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<resources>\n'
    '    <color name="ic_launcher_background">#$backgroundHex</color>\n'
    '</resources>\n',
  );
  const iosFolder = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final catalog =
      jsonDecode(
            File('${root.path}/$iosFolder/Contents.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final entry in catalog['images'] as List) {
    final points = double.parse((entry['size'] as String).split('x').first);
    final scale = double.parse((entry['scale'] as String).replaceAll('x', ''));
    export(
      '$iosFolder/${entry['filename'] as String}',
      (points * scale).round(),
    );
  }
  stdout.writeln(
    'Exported $count platform icons. Adaptive background: #$backgroundHex',
  );
}
