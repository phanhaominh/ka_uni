package com.dandemidov.kit_mobile

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        deepLinkChannel =
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                DEEP_LINK_CHANNEL,
            ).also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        // Cold start: a kauni:// launch put the payload
                        // into the launch intent; Dart pulls it once at
                        // startup and feeds the notification deep-link queue.
                        "takeLaunchPayload" ->
                            result.success(intent.getStringExtra(EXTRA_DEEP_LINK))
                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm start: DeepLinkActivity forwarded a kauni:// token into the
        // live task; push it straight to the same Dart queue. No extra =
        // not a deep link, stay silent.
        val payload = intent.getStringExtra(EXTRA_DEEP_LINK) ?: return
        deepLinkChannel?.invokeMethod("onDeepLink", payload)
    }

    private var deepLinkChannel: MethodChannel? = null

    companion object {
        const val EXTRA_DEEP_LINK =
            "com.dandemidov.kit_mobile.deeplink.PAYLOAD"
        private const val DEEP_LINK_CHANNEL =
            "com.dandemidov.kit_mobile/deeplink"
    }
}
