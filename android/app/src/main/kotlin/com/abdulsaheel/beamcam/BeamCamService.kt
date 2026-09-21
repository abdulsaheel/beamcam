package com.abdulsaheel.beamcam

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the camera alive while BeamCam is in the background.
 *
 * Android has blocked background camera access since Android 9, and WebRTC
 * takes its capture rotation from the activity's orientation — so without a
 * foreground service, backgrounding the app both stops capture and flips the
 * stream to portrait. Started only when the user opts in.
 */
class BeamCamService : Service() {

    companion object {
        const val CHANNEL_ID = "beamcam_streaming"
        const val NOTIFICATION_ID = 0xBEA3
        private const val EXTRA_VIDEO = "video"
        private const val EXTRA_AUDIO = "audio"

        // Android 14+ requires every foreground-service type actually in use
        // to be declared both in the manifest and passed to startForeground;
        // audio can now run independently of video (see sender_page.dart's
        // _videoEnabled/_audioEnabled), so the type has to reflect whichever
        // track(s) are actually live rather than always claiming camera.
        fun start(context: android.content.Context, video: Boolean = true, audio: Boolean = false) {
            val intent = Intent(context, BeamCamService::class.java).apply {
                putExtra(EXTRA_VIDEO, video)
                putExtra(EXTRA_AUDIO, audio)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: android.content.Context) {
            context.stopService(Intent(context, BeamCamService::class.java))
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // From Android 10 the type must be declared for camera/mic access
            // to survive backgrounding; from 14 it must also be passed here,
            // matching whichever track(s) this session actually has enabled.
            val video = intent?.getBooleanExtra(EXTRA_VIDEO, true) ?: true
            val audio = intent?.getBooleanExtra(EXTRA_AUDIO, false) ?: false
            var type = 0
            if (video) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            if (audio) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            if (type == 0) type = ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            startForeground(NOTIFICATION_ID, notification, type)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Do not resurrect the service on its own: streaming is meaningless
        // without the peer connection the activity owns.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Streaming",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shown while BeamCam streams your camera in the background"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = launch?.let {
            PendingIntent.getActivity(
                this, 0, it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("BeamCam is streaming")
            .setContentText("Your camera is being sent to your Mac")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .apply { pending?.let { setContentIntent(it) } }
            .build()
    }
}
