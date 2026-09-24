# The local preview stays instrumentable: the test APK calls these public APIs
# after R8 has independently optimized the application APK. Release does not
# use these additional test-compatibility rules.
-keep class com.securepass.vault.** { *; }
-keep class kotlin.** { *; }
-keep class kotlinx.coroutines.** { *; }
# MockWebServer/okhttp-tls in the test APK call APIs unused by the main app.
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# Instrumentation ViewCapture uses future adapter APIs outside the app call graph.
-keep class androidx.concurrent.futures.** { *; }
