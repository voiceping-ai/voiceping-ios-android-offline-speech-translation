pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

@Suppress("UnstableApiUsage")
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        flatDir { dirs("${rootProject.projectDir}/app/libs") }
    }
}

rootProject.name = "VoicePingIOSAndroidOfflineSpeechTranslation"
include(":app")
