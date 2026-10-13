import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名（A0b，`reply_review.md` §CV·二十二）：口令与 keystore 路径**一律不进仓库**。
// 照 `key.properties.example` 复制一份 `key.properties` 填自己的值即可（已被 .gitignore 排除）。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

// ── 配置校验（A0b·补 2，2026-10-10）：把「填错」的病因**当场说清**，而不是留到签名阶段 ──
// 只在 `key.properties` **存在**时校验：没有这份文件 ⇒ 走下面的 debug 回退（冒烟路径照常可用）。
// 三条都是**真实踩过的**（§CV·二十二·六）：填成非路径、口令是中文、四项漏填。
if (keystorePropertiesFile.exists()) {
    val requiredKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")

    // ① 四项缺一不可。缺项会让 `signingConfigs` 拿到 null，报一句看不懂的话 ⇒ 提前拦。
    val blankOrMissing = requiredKeys.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (blankOrMissing.isNotEmpty()) {
        throw GradleException(
            """
            android/key.properties 填得不完整 —— 缺项（或值为空）：${blankOrMissing.joinToString(" / ")}
              四项缺一不可：${requiredKeys.joinToString(" / ")}
              照 android/key.properties.example 填（口令只能用 ASCII）。
              只想跑 debug 冒烟 ⇒ 把 android/key.properties 删掉或改名，即走 debug 回退。
            """.trimIndent()
        )
    }

    // ② 值只能是 ASCII：Java 的 `Properties.load(InputStream)` 按 ISO-8859-1 解码，
    //    中文口令/路径会被解成乱码 ⇒ 口令**永远**对不上（改到天荒地老也构不过）。
    val nonAscii = requiredKeys.filter { key ->
        keystoreProperties.getProperty(key).orEmpty().any { it.code > 0x7F }
    }
    if (nonAscii.isNotEmpty()) {
        throw GradleException(
            """
            android/key.properties 这些项含非 ASCII 字符（中文等）：${nonAscii.joinToString(" / ")}
              Java 读 .properties 走 ISO-8859-1 ⇒ 中文会被解成乱码，口令必然对不上。
              请把口令 / 路径改成纯 ASCII（字母、数字、符号）。
            """.trimIndent()
        )
    }

    // ③ `storeFile` 必须是**真实存在的文件**。这是最常踩的一条：
    //    填成别的字符串时 Gradle 按 `file(...)` 相对 `android/app/` 解析，
    //    只报一句 `Keystore file '...' not found`；这里把它**解析成了什么**一并打出来。
    val storeFilePath = keystoreProperties.getProperty("storeFile").orEmpty()
    val storeFileResolved = file(storeFilePath)
    if (!storeFileResolved.isFile) {
        throw GradleException(
            """
            android/key.properties 的 storeFile 不是「一个存在的文件」。
              填写的值：$storeFilePath
              解析结果：${storeFileResolved.absolutePath}
                （`file(...)` 相对 android/app/ 解析 ⇒ 建议直接填绝对路径，
                  如 D:/shensuanzi-keys/shensuanzi-release.jks）
              生成 keystore 的命令见 android/key.properties.example 的「第一步」。
            """.trimIndent()
        )
    }

    // ④ 三道全过 ⇒ 打一行「这次用的是哪把钥匙」，便于事后核对产物是不是它签的。
    //    只打**路径 + alias**，绝不打印口令。
    logger.lifecycle(
        "发布签名已就绪：" +
            "${storeFileResolved.absolutePath}（alias=${keystoreProperties.getProperty("keyAlias")}）"
    )
}

android {
    namespace = "com.shensuanzi.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // §AH-1 裁定（2026-09-29）：包名 com.shensuanzi.app（不用 com.example）
        applicationId = "com.shensuanzi.app"
        // §AH-2 裁定：minSdk 24（Android 7，按「个体户手上的旧机」定）；
        // compileSdk / targetSdk 用最新，不为兼容旧机降 target
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 有 key.properties ⇒ 真正的发布签名；没有 ⇒ 见下面 buildTypes 的说明。
    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // ⚠️ 没有 `key.properties` 时**回退 debug 签名** —— 只是为了不让
            // `flutter build apk --debug` / `--release` 在配好签名前直接报错。
            // **这种 release 产物不可分发**（用 debug 密钥签的），
            // A2b 的 `packaging/make_android_release.py` 会**拒绝**它（照
            // `make_manual_html.dart` / `make_release.py`「不合格就拒绝产出」的先例）。
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "⚠️ 没有 android/key.properties ⇒ release 用 debug 签名，产物不可分发。" +
                        "照 key.properties.example 配好再出发布包。"
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
