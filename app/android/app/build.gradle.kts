import org.gradle.api.GradleException
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val requiredKeystoreKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
if (keystorePropertiesFile.exists()) {
    requiredKeystoreKeys.forEach { key ->
        if (keystoreProperties.getProperty(key).isNullOrBlank()) {
            throw GradleException("Missing '$key' in android/key.properties")
        }
    }
}

val releaseTaskRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (releaseTaskRequested && !keystorePropertiesFile.exists()) {
    throw GradleException(
        "Missing android/key.properties for release signing. " +
            "Create a persistent keystore to produce updatable APKs."
    )
}

android {
    namespace = "com.pingtunnel.client.app"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Unique Android package ID for this app.
        applicationId = "com.pingtunnel.client.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                val configuredStorePath = keystoreProperties.getProperty("storeFile")
                val resolvedStoreFile = if (File(configuredStorePath).isAbsolute) {
                    File(configuredStorePath)
                } else {
                    rootProject.file(configuredStorePath)
                }
                if (!resolvedStoreFile.exists()) {
                    throw GradleException(
                        "Keystore file '${resolvedStoreFile.absolutePath}' not found. " +
                            "Check storeFile in android/key.properties."
                    )
                }
                storeFile = resolvedStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
