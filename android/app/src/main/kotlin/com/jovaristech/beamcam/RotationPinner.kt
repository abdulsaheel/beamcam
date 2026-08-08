package com.jovaristech.beamcam

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame

/**
 * Freezes the rotation tag on outgoing camera frames.
 *
 * libwebrtc derives capture rotation from the *display* rotation, not from the
 * activity's requested orientation. The moment BeamCam goes to the background
 * the display reverts to the system orientation and every frame starts being
 * tagged portrait, so the Mac flips mid-stream even though the phone never
 * physically moved.
 *
 * Rather than compute the "right" rotation — which depends on sensor mounting
 * and varies by device — this latches whatever rotation the first frame carried
 * while the app was still foreground and correctly oriented, then applies that
 * to everything after.
 */
object RotationPinner {

    private val pinners = HashMap<String, Pinner>()

    class Pinner : LocalVideoTrack.ExternalVideoFrameProcessing {
        @Volatile
        var pinned: Int? = null

        fun relatch() {
            pinned = null
        }

        override fun onFrame(frame: VideoFrame): VideoFrame {
            val target = pinned ?: frame.rotation.also { pinned = it }
            if (target == frame.rotation) return frame

            // Borrowed, not retained: the capturer still owns the buffer and
            // VideoSink.onFrame does not take ownership, so this wrapper must
            // not release it.
            return VideoFrame(frame.buffer, target, frame.timestampNs)
        }
    }

    /// Returns false when the track id is unknown or is not a video track.
    fun pin(trackId: String): Boolean {
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return false
        val track = plugin.getLocalTrack(trackId) as? LocalVideoTrack ?: return false

        val existing = pinners[trackId]
        if (existing != null) {
            existing.relatch()
            return true
        }

        val pinner = Pinner()
        pinners[trackId] = pinner
        track.addProcessor(pinner)
        return true
    }

    fun unpin(trackId: String) {
        val pinner = pinners.remove(trackId) ?: return
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: return
        (plugin.getLocalTrack(trackId) as? LocalVideoTrack)?.removeProcessor(pinner)
    }
}
