plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.otaku.app"
    compileSdk = flutter.compileSdkVersion
    // 必须与已安装的 NDK 一致，否则 AGP 会报 "NDK not configured"。
    // Flutter 3.47 的 Gradle 插件会强制要求 NDK，本机已装 28.2.13676358。
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications（追番提醒，W1.3a）用了 java.time，
        // 需要开启 core library desugaring 才能在 minSdk 24 上跑。
        // 不开的话构建会直接失败，报 "requires core library desugaring"。
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.otaku.app"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 与上面的 isCoreLibraryDesugaringEnabled 配套。
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
