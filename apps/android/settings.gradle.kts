pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "PasswordVaultNative"

include(":app")

// Separate local QA target; never packaged into the vault application.
include(":login-fixture")

include(":common-relay")
project(":common-relay").projectDir = file("../../vendor/common-relay/java")
