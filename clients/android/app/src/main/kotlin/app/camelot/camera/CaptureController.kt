package app.camelot.camera

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaRecorder
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.util.Size
import android.view.Surface
import java.io.File
import java.util.UUID

/**
 * Camera2 with up to three outputs: the on-screen preview, the stream encoder's surface and a
 * MediaRecorder surface for the local 1080p file. Phones that refuse three streams fall back to
 * preview + stream (no local file), which the UI reports.
 */
class CaptureController(private val context: Context, private val hostTime: () -> Double, private val onPacket: (ByteArray) -> Unit,
                        private val onState: (String) -> Unit) {
    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    private val thread = HandlerThread("camelot-camera").apply { start() }
    private val handler = Handler(thread.looper)
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var previewSurface: Surface? = null
    private var encoder: StreamEncoder? = null
    private var recorder: MediaRecorder? = null
    private var recorderSurface: Surface? = null
    private var cameraID = ""
    /** Width ÷ height of the preview buffer; the view letterboxes to it. */
    @Volatile var previewAspect = 16f / 9f; private set
    var recordsLocally = true; private set
    var isRecording = false; private set
    var recordingFile: File? = null; private set
    var recordingID: UUID? = null; private set
    var recordingStartedAt = 0.0; private set
    var firstFrameHostTime = 0.0; private set

    val elapsedSeconds: Double get() = if (isRecording) ClockSync.localNow() - recordingStartedAt else 0.0

    @SuppressLint("MissingPermission")
    fun start(preview: SurfaceTexture) {
        cameraID = manager.cameraIdList.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
            ?: manager.cameraIdList.first()
        val characteristics = manager.getCameraCharacteristics(cameraID)
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)!!
        // 16:9 like the stream and the recording, so the on-screen preview shows the real framing.
        val sizes = map.getOutputSizes(SurfaceTexture::class.java).filter { it.width <= 1920 && it.height <= 1080 }
        val previewSize = sizes.filter { it.width * 9 == it.height * 16 }.maxByOrNull { it.width * it.height } ?: sizes.maxByOrNull { it.width * it.height } ?: Size(1280, 720)
        preview.setDefaultBufferSize(previewSize.width, previewSize.height)
        previewAspect = previewSize.width.toFloat() / previewSize.height
        previewSurface = Surface(preview)
        encoder = StreamEncoder(hostTime = hostTime, onPacket = onPacket)
        manager.openCamera(cameraID, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) { device = camera; configure(withRecorder = true) }
            override fun onDisconnected(camera: CameraDevice) { camera.close(); device = null; onState("Camera disconnected") }
            override fun onError(camera: CameraDevice, error: Int) { camera.close(); device = null; onState("Camera error $error") }
        }, handler)
    }

    /** Preview + stream, plus the recorder surface when requested. A rejected trio retries as a pair. */
    private fun configure(withRecorder: Boolean) {
        val device = device ?: return
        val preview = previewSurface ?: return
        val stream = encoder?.inputSurface ?: return
        session?.close(); session = null
        val surfaces = mutableListOf(preview, stream)
        if (withRecorder) {
            prepareRecorder(UUID.randomUUID())?.let { surfaces.add(it) } ?: run { recordsLocally = false }
        }
        @Suppress("DEPRECATION")
        device.createCaptureSession(surfaces, object : CameraCaptureSession.StateCallback() {
            override fun onConfigured(session: CameraCaptureSession) {
                this@CaptureController.session = session
                val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                    surfaces.forEach(::addTarget)
                    set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                    set(CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE, CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON)
                }
                session.setRepeatingRequest(request.build(), null, handler)
                onState(if (recordsLocally && withRecorder) "ready" else "ready-stream-only")
            }
            override fun onConfigureFailed(session: CameraCaptureSession) {
                Log.w("CaptureController", "session configuration failed (withRecorder=$withRecorder)")
                if (withRecorder) { releaseRecorder(); recordsLocally = false; configure(withRecorder = false) }
                else onState("Could not configure the camera")
            }
        }, handler)
    }

    /**
     * MediaRecorder needs its surface before the session exists, so a recorder is prepared for the
     * *next* take whenever a session is (re)configured; starting a take just calls `start()`.
     */
    private fun prepareRecorder(id: UUID): Surface? {
        val folder = context.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: context.filesDir
        val file = File(folder, "$id.mp4")
        return try {
            val recorder = MediaRecorder().apply {
                setAudioSource(MediaRecorder.AudioSource.CAMCORDER)
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setOutputFile(file.absolutePath)
                setVideoEncodingBitRate(12_000_000)
                setVideoFrameRate(30)
                setVideoSize(1920, 1080)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioEncodingBitRate(128_000)
                setAudioSamplingRate(44_100)
                setOrientationHint(0)
                prepare()
            }
            this.recorder = recorder
            recordingFile = file
            recordingID = id
            recorderSurface = recorder.surface
            recorder.surface
        } catch (error: Exception) {
            Log.w("CaptureController", "recorder unavailable", error)
            file.delete()
            null
        }
    }

    private fun releaseRecorder() {
        runCatching { recorder?.reset(); recorder?.release() }
        recorder = null; recorderSurface = null
        recordingFile?.takeIf { !isRecording }?.delete()
    }

    /** The host chose the id; the prepared file is renamed to it so both libraries agree. */
    fun startRecording(id: UUID): Boolean {
        val recorder = recorder ?: return false
        if (isRecording) return false
        return try {
            recorder.start()
            Log.i("CaptureController", "recording started $id → ${recordingFile?.name}")
            recordingStartedAt = ClockSync.localNow()
            firstFrameHostTime = hostTime()
            isRecording = true
            recordingID = id
            true
        } catch (error: Exception) {
            Log.w("CaptureController", "start failed", error); false
        }
    }

    data class Take(val id: UUID, val file: File, val durationSeconds: Double, val firstFrameHostTime: Double)

    /** Stops and returns the take (file renamed to the host's id); null if nothing was recording. */
    fun stopRecording(): Take? {
        val recorder = recorder ?: return null
        if (!isRecording) return null
        val duration = elapsedSeconds
        isRecording = false
        val file = recordingFile ?: return null
        val id = recordingID ?: return null
        runCatching { recorder.stop() }
        runCatching { recorder.release() }
        this.recorder = null
        val renamed = File(file.parentFile, "$id.mp4")
        val finalFile = if (renamed != file && file.renameTo(renamed)) renamed else file
        val take = Take(id, finalFile, duration, firstFrameHostTime)
        Log.i("CaptureController", "recording stopped ${finalFile.name} ${finalFile.length()} bytes, ${"%.1f".format(duration)} s")
        recordingFile = null; recordingID = null
        // The recorder surface is dead now; rebuild the session with a fresh one for the next take.
        handler.post { configure(withRecorder = true) }
        return take
    }

    fun pauseStream(paused: Boolean) { encoder?.paused = paused }

    fun stop() {
        runCatching { session?.stopRepeating() }
        session?.close(); session = null
        device?.close(); device = null
        if (isRecording) runCatching { recorder?.stop() }
        releaseRecorder()
        encoder?.release(); encoder = null
        previewSurface?.release(); previewSurface = null
        thread.quitSafely()
    }
}
