package com.yantrixlabs.camnexo_mobile

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var sink: EventChannel.EventSink? = null
    private var discoverySink: EventChannel.EventSink? = null
    private lateinit var stream: StreamController
    private lateinit var discovery: DiscoveryController

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // The stream outlives this screen (a foreground service keeps it going in the background),
        // so it is a process-wide object that this activity attaches to while it exists.
        stream = StreamController.get(this)
        stream.activity = this
        stream.emit = { event -> runOnUiThread { sink?.success(event) } }
        discovery = DiscoveryController(this) { event -> runOnUiThread { discoverySink?.success(event) } }

        EventChannel(messenger, "camnexo/discovery/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    discoverySink = events
                }

                override fun onCancel(arguments: Any?) {
                    discoverySink = null
                }
            }
        )

        MethodChannel(messenger, "camnexo/discovery").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    discovery.start()
                    result.success(null)
                }
                "stop" -> {
                    discovery.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, "camnexo/stream/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    sink = events
                    // A screen opened again while a stream is running: show it as streaming.
                    stream.replayState()
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            }
        )

        MethodChannel(messenger, "camnexo/stream").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    askForNotificationPermission()
                    stream.start(
                        host = call.argument<String>("host") ?: "",
                        port = call.argument<Int>("port") ?: 7878,
                        front = call.argument<Boolean>("front") ?: false,
                    )
                    result.success(null)
                }
                "stop" -> {
                    stream.stop()
                    result.success(null)
                }
                "switchCamera" -> {
                    stream.switchCamera(call.argument<Boolean>("front") ?: false)
                    result.success(null)
                }
                "setTorch" -> {
                    stream.setTorch(call.argument<Boolean>("on") ?: false)
                    result.success(null)
                }
                "setZoom" -> {
                    stream.setZoom((call.argument<Double>("ratio") ?: 1.0).toFloat())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Android 13+ hides the "CamNexo is streaming" notification (with its Stop button) until
     * allowed. Streaming works either way, so this only asks and does not wait.
     */
    private fun askForNotificationPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7879)
    }

    override fun onResume() {
        super.onResume()
        // Back in front while streaming: keep the display on again.
        if (::stream.isInitialized && stream.isRunning) stream.keepScreenOn(true)
    }

    override fun onDestroy() {
        if (::stream.isInitialized) {
            // Closing the app (back button or swiped away) ends the stream. Being destroyed by the
            // system (for example a settings change) must not: the service keeps it going.
            if (isFinishing) stream.stop(emitIdle = false)
            stream.emit = {}
            stream.activity = null
        }
        if (::discovery.isInitialized) discovery.stop()
        super.onDestroy()
    }
}
