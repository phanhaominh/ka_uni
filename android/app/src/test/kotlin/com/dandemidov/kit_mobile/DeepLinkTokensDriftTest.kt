package com.dandemidov.kit_mobile

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * R37b drift guard: DeepLinkActivity.TOKENS is a FIXED copy of the Dart
 * NotificationPayload constants - until now guarded only by a comment, and
 * the whole Kotlin file was untested (the Flutter suite cannot reach it).
 * These tests parse both sources; adding or renaming a payload in Dart
 * WITHOUT mirroring it in TOKENS fails :app:testDebugUnitTest exactly like
 * the Dart-side l10n mirrors fail flutter test. (" in a regex via \u0022.)
 */
class DeepLinkTokensDriftTest {
    private fun repoFile(vararg parts: String): File {
        // Gradle unit tests run with the module directory (android/app) as
        // working directory -> ../../ is the repo root
        val f = File(listOf("..", "..", *parts).joinToString(File.separator))
        require(f.exists()) { "missing $f" }
        return f
    }

    private fun kotlinSource() = repoFile(
        "android", "app", "src", "main", "kotlin", "com", "dandemidov",
        "kit_mobile", "DeepLinkActivity.kt"
    ).readText()

    @Test
    fun kotlinTokenValuesMirrorDartPayloads() {
        val kt = kotlinSource()
        val dart = repoFile("lib", "notifications", "notification_payload.dart")
            .readText()

        val kotlinValues =
            Regex("\u0022([a-z/]+)\u0022 to \u0022([a-z:]+)\u0022")
                .findAll(kt).map { it.groupValues[2] }.toSet()
        val dartValues =
            Regex("static const \\w+ = '([a-z:]+)';")
                .findAll(dart).map { it.groupValues[1] }.toSet()

        assertEquals(
            "NotificationPayload and DeepLinkActivity.TOKENS diverged - " +
                "mirror the payload in TOKENS (every URL spelling!)",
            dartValues,
            kotlinValues
        )
    }

    @Test
    fun everyUrlEntryPointStillExists() {
        val keys = Regex("\u0022([a-z/]+)\u0022 to")
            .findAll(kotlinSource()).map { it.groupValues[1] }.toSet()
        val expected = setOf(
            "agenda", "agenda/today", "agenda/changes", "today", "changes",
            "exams", "grades", "library", "library/checkin"
        )
        assertEquals(
            "TOKENS lost or renamed a URL entry point (DeepLinkActivity " +
                "and the notification link builders must agree)",
            expected,
            keys
        )
    }
}
