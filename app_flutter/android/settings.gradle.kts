pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 8, no 9. Con AGP 9 los plugins de la comunidad (device_info_plus,
    // que entra por vibration) dejan de aplicar el plugin de Kotlin dando por
    // hecho que lo trae AGP; el proyecto no llega a configurarse y el build
    // muere con un NullPointerException disfrazado de "does not specify
    // compileSdk". Subir a 9 exige que TODOS los plugins se hayan actualizado.
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
