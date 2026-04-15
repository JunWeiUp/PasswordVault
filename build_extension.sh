#!/bin/bash

# Exit on error
set -e

echo "🚀 Starting Chrome Extension build process..."

# 1. Build Flutter Web
echo "📦 Building Flutter web with source maps..."
flutter pub get
# 移除插件等依赖变更后，旧的 web_plugin_registrant 会仍引用已删除包导致编译失败
rm -rf .dart_tool/flutter_build
# 在新版本 Flutter 中，--web-renderer 选项已被移除或更改。
# 我们在 loader.js 中强制 initializeEngine 使用 'html' 渲染器。
# --no-wasm-dry-run：避免部分环境下 dart2wasm dry run 报错中断流程
flutter build web --release --no-tree-shake-icons --source-maps --no-wasm-dry-run

# 2. Prepare build directory
EXT_DIR="build/chrome_extension"
echo "🧹 Cleaning and preparing directory: $EXT_DIR"
rm -rf "$EXT_DIR"
mkdir -p "$EXT_DIR"

# 3. Copy built files
echo "📂 Copying web assets..."
cp -r build/web/* "$EXT_DIR/"

# 3.5 Copy CanvasKit (Ensure it's local)
if [ -d "build/web/canvaskit" ]; then
  echo "📂 Copying local CanvasKit..."
  cp -r build/web/canvaskit "$EXT_DIR/"
fi

# 4. Copy extension specific files
echo "📂 Copying extension configuration..."
cp chrome/manifest.json "$EXT_DIR/"
cp chrome/background.js "$EXT_DIR/"
cp chrome/content.js "$EXT_DIR/"
cp -r chrome/icons "$EXT_DIR/"

# 5. Create style.css (External to avoid CSP issues)
echo "🎨 Creating style.css..."
cat > "$EXT_DIR/style.css" <<EOF
html, body {
  width: 400px;
  height: 600px;
  margin: 0;
  padding: 0;
  overflow: hidden;
  background-color: #ffffff;
}
EOF

# 6. Create loader.js (External to avoid CSP issues)
echo "⚙️ Creating loader.js..."
cat > "$EXT_DIR/loader.js" <<EOF
console.log("🚀 Loader starting...");

// Global error handler for better debugging
window.onerror = function(message, source, lineno, colno, error) {
  console.error("❌ Global JS Error:", message, "at", source, ":", lineno, ":", colno);
  if (error && error.stack) console.error(error.stack);
  return false;
};

window.onunhandledrejection = function(event) {
  console.error("❌ Unhandled Promise Rejection:", event.reason);
};

// Bridge for Flutter to communicate with Chrome Extension API
window.hasChromeApi = function() {
  const has = typeof chrome !== 'undefined' && !!chrome.runtime && !!chrome.runtime.id;
  console.log("🔍 hasChromeApi check:", has);
  return has;
};

window.chromeSendMessage = function(message) {
  console.log("📤 Sending message to background:", message.type || 'unknown');
  return new Promise((resolve, reject) => {
    if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
      chrome.runtime.sendMessage(message, (response) => {
        if (chrome.runtime.lastError) {
          console.warn("⚠️ chromeSendMessage error:", chrome.runtime.lastError.message);
          resolve(null);
        } else {
          console.log("📥 Received response:", response ? 'success' : 'null');
          resolve(response || null);
        }
      });
    } else {
      console.warn("⚠️ Chrome Extension API not available for sendMessage");
      resolve(null);
    }
  });
};

window.chromeStorageGet = function(key) {
  console.log("📦 Reading from storage:", key);
  return new Promise((resolve) => {
    if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
      chrome.storage.local.get([key], (result) => {
        if (chrome.runtime.lastError) {
          console.warn("⚠️ chromeStorageGet error:", chrome.runtime.lastError.message);
          resolve(null);
        } else {
          resolve(result[key] || null);
        }
      });
    } else {
      console.warn("⚠️ Chrome Storage API not available");
      resolve(null);
    }
  });
};

window.chromeStorageSet = function(key, value) {
  console.log("📦 Writing to storage:", key);
  return new Promise((resolve) => {
    if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
      const data = {};
      data[key] = value;
      chrome.storage.local.set(data, () => {
        if (chrome.runtime.lastError) {
          console.warn("⚠️ chromeStorageSet error:", chrome.runtime.lastError.message);
        }
        resolve(null);
      });
    } else {
      console.warn("⚠️ Chrome Storage API not available");
      resolve(null);
    }
  });
};

window.chromeStorageRemove = function(key) {
  console.log("🗑️ Removing from storage:", key);
  return new Promise((resolve) => {
    if (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) {
      chrome.storage.local.remove([key], () => {
        resolve(null);
      });
    } else {
      resolve(null);
    }
  });
};

window.addEventListener('load', function(ev) {
  console.log("🚀 window load event fired");
  
  // 强制使用本地 CanvasKit
  window.flutterConfiguration = {
    canvasKitBaseUrl: "canvaskit/"
  };

  _flutter.loader.loadEntrypoint({
    serviceWorkerSettings: null,
    onEntrypointLoaded: function(engineInitializer) {
      console.log("📦 entrypoint loaded, initializing engine...");
      
      const config = {
        canvasKitBaseUrl: "canvaskit/",
        useColorEmoji: true
      };

      engineInitializer.initializeEngine(config).then(function(appRunner) {
        console.log("🏃 engine initialized, running app...");
        appRunner.runApp();
      }).catch(function(err) {
        console.error("❌ Engine initialization failed:", err);
        // 如果 CanvasKit 初始化失败，尝试强制使用 HTML 渲染器
        console.log("🔄 Retrying with HTML renderer...");
        engineInitializer.initializeEngine({
            renderer: 'html'
        }).then(function(appRunner) {
            appRunner.runApp();
        });
      });
    }
  });
});
EOF

# 7. Patch index.html
echo "🛠 Patching index.html..."
# Use a temporary file for patching
TEMP_HTML="$EXT_DIR/index.temp.html"

# We want a very clean index.html. We'll rebuild it slightly.
cat > "$TEMP_HTML" <<EOF
<!DOCTYPE html>
<html>
<head>
  <base href="./">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <meta name="description" content="SecurePass Chrome Extension">
  <title>SecurePass</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <script src="flutter.js" defer></script>
  <script src="loader.js" defer></script>
</body>
</html>
EOF

mv "$TEMP_HTML" "$EXT_DIR/index.html"

# 8. Clean up manifest.json (the web one)
if [ -f "$EXT_DIR/manifest.json" ]; then
  # Ensure we are using the chrome one, which we already copied
  echo "✅ Extension manifest is ready."
fi

echo "✨ Build completed! You can now load '$EXT_DIR' as an unpacked extension in Chrome."
