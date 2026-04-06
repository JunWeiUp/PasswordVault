# Flutter 默认混淆规则
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class com.google.crypto.tink.** { *; }
-keep class org.sqlite.** { *; }

# 保留自动填充服务类 (Android 系统调用)
-keep class com.example.password.autofill.SecurePassAutofillService { *; }
-keep class com.example.password.MainActivity { *; }

# 忽略缺失的 Google Play Core 库 (通常不需要)
-dontwarn com.google.android.play.core.**

# 忽略 Tink 的可选依赖
-dontwarn com.google.api.client.http.**
-dontwarn com.google.api.client.json.**
-dontwarn com.google.crypto.tink.util.KeysDownloader
-dontwarn com.google.crypto.tink.util.KeysDownloader$Builder
-dontwarn org.joda.time.Instant

# 防止资源压缩误删某些必要的资源
-keepclassmembers class **.R$* {
    public static <fields>;
}
