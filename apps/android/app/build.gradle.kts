import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release credentials are generated only in the protected CI environment.
val releasePropertiesFile = rootProject.file("../../android/key.properties")
val releaseProperties = Properties().apply {
    if (releasePropertiesFile.isFile) releasePropertiesFile.inputStream().use { load(it) }
}
val hasReleaseSigning = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .all { !releaseProperties.getProperty(it).isNullOrEmpty() }

android {
    namespace = "com.securepass.vault"
    compileSdk = 36
    ndkVersion = "27.0.12077973"
    defaultConfig {
        applicationId = "com.securepass.vault"
        minSdk = 24
        targetSdk = 36
        versionCode = 22002
        versionName = "2.2.1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        testProguardFile("test-proguard-rules.pro")
        ndk {
            val requestedAbi = providers.gradleProperty("targetAbi").orNull
            require(requestedAbi == null || requestedAbi in listOf("arm64-v8a", "x86_64"))
            abiFilters += requestedAbi?.let(::listOf) ?: listOf("arm64-v8a", "x86_64")
        }
    }
    signingConfigs {
        if (hasReleaseSigning) create("publicRelease") {
            storeFile = file(releaseProperties.getProperty("storeFile"))
            storePassword = releaseProperties.getProperty("storePassword")
            keyAlias = releaseProperties.getProperty("keyAlias")
            keyPassword = releaseProperties.getProperty("keyPassword")
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".nativepreview"
            versionNameSuffix = "-preview"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        create("previewRelease") {
            initWith(getByName("release"))
            // Keep the native vault separate until legacy migration gates pass.
            applicationIdSuffix = ".nativepreview"
            matchingFallbacks += "release"
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("publicRelease")
        }
        create("compact") {
            initWith(getByName("debug"))
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            proguardFile("compact-proguard-rules.pro")
            matchingFallbacks += "debug"
        }
    }
    testBuildType = providers.gradleProperty("testBuildType").orElse("debug").get()
    sourceSets["main"].java.srcDir("src/main/generated")
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    packaging {
        jniLibs { useLegacyPackaging = false }
        resources.excludes += "META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
    implementation("androidx.concurrent:concurrent-futures-ktx:1.2.0")
    implementation("io.noties.markwon:core:4.6.2")
    implementation("org.java-websocket:Java-WebSocket:1.5.7")
    implementation("com.google.zxing:core:3.5.3")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.compose.material3:material3:1.4.0")
    implementation("androidx.compose.material:material-icons-extended:1.7.8")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    androidTestImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    androidTestImplementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.uiautomator:uiautomator:2.3.0")
}

// Fail closed: never publish an unsigned or debug-signed native release.
tasks.configureEach {
    if (name == "prePreviewReleaseBuild") doFirst {
        check(hasReleaseSigning) { "Public native release requires protected signing configuration." }
    }
}
