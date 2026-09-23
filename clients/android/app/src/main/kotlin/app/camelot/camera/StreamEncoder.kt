package app.camelot.camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer

/**
 * 720p H.264 from a camera-fed input surface, delivered as `Wire.videoPacket` bodies. Keyframes
 * every second; SPS/PPS from the codec's config buffer are attached to every keyframe.
 */
class StreamEncoder(val width: Int = 1280, val height: Int = 720, private val bitRate: Int = 3_500_000,
                    private val hostTime: () -> Double, private val onPacket: (ByteArray) -> Unit) {
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    val inputSurface: Surface
    private var parameterSets: List<ByteArray> = emptyList()
    @Volatile private var running = true
    @Volatile var paused = false

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
        }
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = codec.createInputSurface()
        codec.start()
        Thread(::drain, "camelot-encoder").start()
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        while (running) {
            val index = try { codec.dequeueOutputBuffer(info, 10_000) } catch (error: IllegalStateException) { break }
            if (index < 0) continue
            val buffer = codec.getOutputBuffer(index)
            if (buffer != null && info.size > 0) {
                buffer.position(info.offset); buffer.limit(info.offset + info.size)
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    parameterSets = Wire.splitNalUnits(buffer)
                } else if (!paused) {
                    val keyframe = info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
                    // Timestamp the frame on the shared clock as it leaves the encoder (~1 frame late).
                    onPacket(Wire.videoPacket(hostTime(), keyframe, if (keyframe) parameterSets else emptyList(), Wire.annexBToAvcc(buffer)))
                }
            }
            codec.releaseOutputBuffer(index, false)
        }
    }

    fun release() {
        running = false
        runCatching { codec.signalEndOfInputStream() }
        runCatching { codec.stop() }
        runCatching { codec.release() }
        runCatching { inputSurface.release() }
        Log.i("StreamEncoder", "released")
    }
}
