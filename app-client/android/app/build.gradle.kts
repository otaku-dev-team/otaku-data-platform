import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 正式签名 ──────────────────────────────────────────────────────────
// 密钥**不入库**（android/.gitignore 已排除 key.properties / *.jks / *.keystore）。
// 有密钥的人把 android/key.properties 放本机即可，格式见同目录的
// key.properties.example。
//
// 没有这个文件就退回 debug 签名：协作者和 CI 都没有密钥，硬失败会直接把
// 构建链打断。代价是「可能有人拿 debug 签的包当正式版发出去」，所以下面
// 会打印醒目警告，并且 build_site.sh 可以用 --require-release-key 变成硬失败。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}
val hasReleaseKey =
    keystorePropsFile.exists() && keystoreProps.getProperty("storeFile") != null

android {
    namespace = "com.otaku.app"
    compileSdk = flutter.compileSdkVersion

    buildFeatures {
        // AGP 9 起 resValue 默认关闭，不用就报
        // 「defaultConfig contains custom resource values, but the feature is disabled」。
        // 开它只是为了注入 app_name（见 defaultConfig 里的 resValue）。
        resValues = true
    }

    // 必须与已安装的 NDK 一致，否则 AGP 会报 "NDK not configured"。
    // Flutter 3.47 的 Gradle 插件会强制要求 NDK，本机已装 28.2.13676358。
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 依赖树里仍有插件用到 java.time（minSdk 24 上需要脱糖才能跑）。
        // 不开的话构建会直接失败，报 "requires core library desugaring"。
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 换站时可覆盖（-PappId=...）：「每站一个独立客户端」要求各站的包名不同，
        // 否则同一台设备上只能装一个，且系统会把它们当成同一个应用的升级。
        applicationId = (rootProject.findProperty("appId") as String?) ?: "com.otaku.app"        // 应用名同理（-PappName=...）。用 resValue 而不是改 manifest 里的字符串：
        // manifest 是源文件，每个站改一次会留下 diff 噪音；resValue 由构建参数注入，
        // 源文件不动。默认 "Otaku" 即首站现状。
        resValue("string", "app_name", rootProject.findProperty("appName") as String? ?: "Otaku")
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // debug 由 AGP 默认创建，不用声明。
        if (hasReleaseKey) {
            create("release") {
                storeFile = keystorePropsFile.parentFile.resolve(
                    keystoreProps.getProperty("storeFile"),
                )
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // 没配密钥：能用，但**不能发出去**。debug 证书换台机器重建就变了，
                // 老用户升级会 INSTALL_FAILED_UPDATE_INCOMPATIBLE（装不上更新）。
                signingConfig = signingConfigs.getByName("debug")
                // 用英文：gradle 进程按平台默认编码输出，中文到这里会变乱码，
                // 一条看不懂的警告等于没写。
                println("")
                println("WARNING: release is signed with the DEBUG key (no android/key.properties).")
                println("         This APK must NOT be distributed: rebuilding on another machine")
                println("         changes the signature and users hit INSTALL_FAILED_UPDATE_INCOMPATIBLE.")
                println("         Generate: keytool -genkey -v -keystore android/otaku.jks \\")
                println("             -keyalg RSA -keysize 2048 -validity 10000 -alias otaku")
                println("         Then fill android/key.properties (see key.properties.example).")
                println("")
            }
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
