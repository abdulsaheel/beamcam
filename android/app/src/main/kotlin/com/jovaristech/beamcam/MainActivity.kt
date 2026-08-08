package com.jovaristech.beamcam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "beamcam/service"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startBackground" -> {
                        BeamCamService.start(this)
                        result.success(true)
                    }
                    "stopBackground" -> {
                        BeamCamService.stop(this)
                        result.success(true)
                    }
                    "pinRotation" -> {
                        val trackId = call.argument<String>("trackId")
                        if (trackId == null) {
                            result.error("no_track", "trackId is required", null)
                        } else {
                            result.success(RotationPinner.pin(trackId))
                        }
                    }
                    "unpinRotation" -> {
                        call.argument<String>("trackId")?.let { RotationPinner.unpin(it) }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
