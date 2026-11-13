package com.dandemidov.kit_mobile

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * R35.7: exported entry point for `kauni://<token>` links. Logic-free by
 * design: host + first path segment consult one fixed token table and the
 * verdict (a payload string or nothing) rides to MainActivity as an intent
 * extra. Query, fragment and user-info are never even read, so URL params
 * can never steer routing. Unknown tokens drop the payload: the app still
 * launches and routes nothing, exactly like a tap on a dead notification
 * (the Dart router's payload mapping already no-ops unknown payloads).
 * All real routing lives in the existing notification deep-link queue.
 */
class DeepLinkActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val data = intent?.data
        val token = listOfNotNull(
            data?.host?.lowercase(),
            data?.pathSegments?.firstOrNull()?.lowercase(),
        ).joinToString("/")
        val payload = TOKENS[token]

        // Same task as MainActivity (matching empty taskAffinity): cold
        // start = fresh launch carrying the payload; warm = onNewIntent on
        // the live MainActivity, which forwards the payload to Dart.
        val launch = Intent(this, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP,
            )
            if (payload != null) putExtra(MainActivity.EXTRA_DEEP_LINK, payload)
        }
        startActivity(launch)
        finish() // NoDisplay theme: this activity never draws a window
    }

    private companion object {
        // Fixed mirror of the Dart NotificationPayload tokens (see
        // lib/notifications/notification_payload.dart); "today"/"changes"
        // are the agenda flags spelled as bare hosts, the "agenda/..."
        // forms take the same token as a path segment.
        val TOKENS = mapOf(
            "agenda" to "agenda",
            "agenda/today" to "agenda:today",
            "agenda/changes" to "agenda:changes",
            "today" to "agenda:today",
            "changes" to "agenda:changes",
            "exams" to "exams",
            "grades" to "grades",
            "library" to "library:checkin",
            "library/checkin" to "library:checkin",
        )
    }
}
