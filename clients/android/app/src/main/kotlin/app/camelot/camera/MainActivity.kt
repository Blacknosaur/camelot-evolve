package app.camelot.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.os.BatteryManager
import android.os.Bundle
import android.os.StatFs
import android.view.TextureView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import java.util.UUID

/** One screen: find a host, then be its camera until it ends the session. */
class MainActivity : ComponentActivity(), SessionListener {
    private val prefs by lazy { getSharedPreferences("camelot", Context.MODE_PRIVATE) }
    private val deviceID: UUID by lazy {
        prefs.getString("deviceID", null)?.let(UUID::fromString) ?: UUID.randomUUID().also { prefs.edit().putString("deviceID", it.toString()).apply() }
    }
    private var client: SessionClient? = null
    private var capture: CaptureController? = null
    private var pendingPreview: SurfaceTexture? = null
    private var statusThread: Thread? = null
    private var discoveryWatchdog: Runnable? = null

    // UI state
    private val hosts = mutableStateListOf<DiscoveredHost>()
    private var screen by mutableStateOf(Screen.JOIN)
    private var name by mutableStateOf("")
    private var hostName by mutableStateOf("")
    private var projectName by mutableStateOf("")
    private var status by mutableStateOf("Looking for a session nearby…")
    private var clockSynced by mutableStateOf(false)
    private var clockMs by mutableStateOf(0.0)
    private var hostRecording by mutableStateOf(false)
    private var hostElapsed by mutableStateOf(0.0)
    private var recording by mutableStateOf(false)
    private var cameraState by mutableStateOf("")
    private var transfer by mutableStateOf<Double?>(null)
    private var transferDone by mutableStateOf(false)
    private var permitted by mutableStateOf(false)
    private var previewAspect by mutableStateOf(16f / 9f)
    private var manualAddress by mutableStateOf("")
    private var mode by mutableStateOf("")
    private val sentCounts = mutableStateMapOf<EventKind, Int>()
    private var lastTag by mutableStateOf<EventKind?>(null)

    private enum class Screen { JOIN, CAMERA, REMOTE }

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        permitted = granted.values.all { it }
        if (permitted) startBrowsing() else status = "Camera and microphone permissions are needed."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        name = prefs.getString("name", "") ?: ""
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                Surface(Modifier.fillMaxSize(), color = Color(0xFF0B0C0E)) {
                    when (screen) {
                        Screen.JOIN -> JoinScreen()
                        Screen.CAMERA -> CameraScreen()
                        Screen.REMOTE -> RemoteScreen()
                    }
                }
            }
        }
        val needed = listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        if (needed.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) { permitted = true; startBrowsing() }
        else permissions.launch(needed.toTypedArray())
    }

    override fun onDestroy() { leave(); super.onDestroy() }

    private val displayName: String get() = name.trim().ifEmpty { "Camera · ${android.os.Build.MODEL}" }

    private fun startBrowsing() {
        client?.close()
        val client = SessionClient(this, displayName, deviceID, this).also { it.startBrowsing() }
        this.client = client
        status = "Looking for a session nearby…"
        // NsdManager sometimes registers a listener that never reports anything (common after the
        // app is force-stopped). Retry until something is seen rather than sitting there silent.
        discoveryWatchdog?.let { window.decorView.removeCallbacks(it) }
        val watchdog = object : Runnable {
            override fun run() {
                if (screen != Screen.JOIN || this@MainActivity.client !== client) return
                if (!client.hasDiscovered && hosts.isEmpty()) client.restartBrowsing()
                window.decorView.postDelayed(this, 12_000)
            }
        }
        discoveryWatchdog = watchdog
        window.decorView.postDelayed(watchdog, 12_000)
    }

    private fun connectManually() {
        prefs.edit().putString("name", name).apply()
        val client = client ?: return
        status = "Connecting to $manualAddress…"
        if (!client.connectManually(manualAddress)) status = "That address needs an IP and port, e.g. 192.168.1.40:53084"
    }

    private fun join(host: DiscoveredHost) {
        prefs.edit().putString("name", name).apply()
        status = "Connecting to ${host.name}…"
        client?.stopBrowsing()
        client?.connect(host)
    }

    private fun leave() {
        joining = false
        discoveryWatchdog?.let { window.decorView.removeCallbacks(it) }; discoveryWatchdog = null
        statusThread?.interrupt(); statusThread = null
        capture?.stop(); capture = null
        client?.close(); client = null
        screen = Screen.JOIN
        hosts.clear(); recording = false; transfer = null; transferDone = false; hostRecording = false
        sentCounts.clear(); lastTag = null; mode = ""
    }

    // MARK: SessionListener (main thread)

    override fun onHosts(hosts: List<DiscoveredHost>) {
        this.hosts.clear(); this.hosts.addAll(hosts)
        // `adb shell am start … --ez autoJoin true`: join the first host without a tap (device tests).
        if (screen == Screen.JOIN && intent.getBooleanExtra("autoJoin", false) && hosts.isNotEmpty() && !joining) { joining = true; join(hosts.first()) }
    }
    private var joining = false

    override fun onConnected(hostName: String, projectName: String, projectID: UUID, mode: String) {
        this.hostName = hostName; this.projectName = projectName; this.mode = mode
        val client = client ?: return
        if (mode == "eventRemote") {
            // The host records on its own phone; this one is only a pad, so no camera is opened.
            status = "Tap an event while $hostName records."
            screen = Screen.REMOTE
            sentCounts.clear()
            return
        }
        status = "Connected. The host starts and stops recording."
        screen = Screen.CAMERA
        capture = CaptureController(this, hostTime = { client.hostNow() }, onPacket = { client.send(it) }) { state ->
            runOnUiThread {
                previewAspect = capture?.previewAspect ?: previewAspect
                cameraState = state
                if (state == "ready-stream-only") status = "Streaming only: this phone can't record a local file while streaming."
                else if (state != "ready") status = state
            }
        }
        pendingPreview?.let { capture?.start(it) }
        statusThread = Thread {
            try {
                while (!Thread.interrupted()) {
                    val battery = (getSystemService(Context.BATTERY_SERVICE) as BatteryManager).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) / 100f
                    val free = StatFs(filesDir.path).availableBytes / 1_048_576
                    client.sendStatus(capture?.isRecording == true, capture?.elapsedSeconds ?: 0.0, battery, free.toInt())
                    Thread.sleep(2_000)
                }
            } catch (_: InterruptedException) {}
        }.also { it.start() }
    }

    override fun onDisconnected(reason: String) { leave(); status = reason; startBrowsing() }
    override fun onHostStatus(isRecording: Boolean, elapsedSeconds: Double) { hostRecording = isRecording; hostElapsed = elapsedSeconds }
    override fun onClock(synced: Boolean, uncertaintyMs: Double) { clockSynced = synced; clockMs = uncertaintyMs }

    override fun onStartRecording(recordingID: UUID) {
        val capture = capture ?: return
        transfer = null; transferDone = false
        if (capture.startRecording(recordingID)) {
            recording = true
            client?.sendRecordingStarted(recordingID, capture.firstFrameHostTime)
            status = "Recording · the host stops this camera"
        } else {
            status = if (capture.recordsLocally) "Could not start the local recording; still streaming." else "Streaming only (no local file on this phone)."
        }
    }

    override fun onStopRecording() {
        val capture = capture ?: return
        val take = capture.stopRecording() ?: return
        recording = false
        status = "Saved ${timecode(take.durationSeconds)} locally. Sending to $hostName…"
        transfer = 0.0
        capture.pauseStream(true)
        client?.sendFile(take.id, take.file, take.durationSeconds, take.firstFrameHostTime) { fraction -> transfer = fraction }
    }

    override fun onTransferReceived(recordingID: UUID) {
        transfer = null; transferDone = true
        capture?.pauseStream(false)
        status = "Video delivered to $hostName"
    }

    // MARK: Screens

    @Composable
    private fun JoinScreen() {
        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("Join a session", style = MaterialTheme.typography.headlineSmall, color = Color.White)
            OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("This phone's name (shown to the host)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Text(status, color = Color(0xFFB0B4BD))
            // Some access points drop the multicast that discovery relies on; the host screen
            // shows its address so it can always be reached directly.
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = manualAddress, onValueChange = { manualAddress = it },
                    label = { Text("Host address, e.g. 192.168.1.40:53084") }, singleLine = true,
                    modifier = Modifier.weight(1f),
                )
                Button(onClick = { connectManually() }, enabled = manualAddress.isNotBlank()) { Text("Connect") }
            }
            if (hosts.isEmpty() && permitted) Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.width(20.dp).height(20.dp)); Spacer(Modifier.width(12.dp)); Text("On the iPhone: open the project → Multi-cam session.", color = Color(0xFFB0B4BD)) }
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(hosts, key = { it.name }) { host ->
                    Card(onClick = { join(host) }, modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(16.dp)) {
                            Text(host.project.ifEmpty { host.name }, style = MaterialTheme.typography.titleMedium)
                            Text("${host.name} · join as camera", style = MaterialTheme.typography.bodyMedium, color = Color(0xFFB0B4BD))
                        }
                    }
                }
            }
        }
    }

    @Composable
    private fun CameraScreen() {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView(factory = { context ->
                TextureView(context).apply {
                    // Sized by the parent to the camera's aspect ratio; never stretched to the screen.
                    surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                        override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
                            pendingPreview = texture
                            capture?.start(texture)
                        }
                        override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {}
                        override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean { pendingPreview = null; return true }
                        override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {}
                    }
                }
            }, modifier = Modifier.align(Alignment.Center).fillMaxSize().aspectRatio(previewAspect, matchHeightConstraintsFirst = true))
            Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { leave(); startBrowsing() }, enabled = !recording && transfer == null) { Text("Leave", color = Color.White) }
                Chip(if (recording) "● REC ${timecode(capture?.elapsedSeconds ?: 0.0)}" else projectName, if (recording) Color(0xFFE53935) else Color(0x66000000))
                Chip(hostName, Color(0xFFD1FF40), Color.Black)
            }
            Column(Modifier.align(Alignment.BottomStart).fillMaxWidth().background(Color(0x99000000)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(status, color = Color.White)
                transfer?.let { fraction ->
                    LinearProgressIndicator(progress = { fraction.toFloat() }, modifier = Modifier.fillMaxWidth(), color = Color(0xFFD1FF40))
                    Text("Keep both phones open until the video has arrived · ${(fraction * 100).toInt()}%", color = Color(0xFFB0B4BD))
                }
                Text(if (clockSynced) "Clock synced · ±%.0f ms".format(clockMs) else "Syncing clocks…", color = if (clockSynced) Color(0xFFD1FF40) else Color(0xFFFFB74D))
            }
        }
    }

    /** Event pad: this phone never records, it only sends taps to whoever does. */
    @Composable
    private fun RemoteScreen() {
        val landscape = resources.configuration.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val columns = if (landscape) 3 else 2
        Column(Modifier.fillMaxSize().padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { leave(); startBrowsing() }) { Text("Leave", color = Color.White) }
                Text(projectName, color = Color.White, maxLines = 1)
                Chip(hostName, Color(0xFFD1FF40), Color.Black)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (hostRecording) {
                    Chip("● REC ${timecode(hostElapsed)}", Color(0xFFE53935))
                    Text("${sentCounts.values.sum()} sent", color = Color(0xFFB0B4BD))
                } else {
                    CircularProgressIndicator(Modifier.width(18.dp).height(18.dp), strokeWidth = 2.dp)
                    Text("Waiting for $hostName to start recording", color = Color(0xFFB0B4BD))
                }
            }
            Column(Modifier.fillMaxSize().alpha(if (hostRecording) 1f else 0.5f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                EventKind.entries.chunked(columns).forEach { row ->
                    Row(Modifier.fillMaxWidth().weight(1f), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { kind -> Pad(kind, Modifier.weight(1f).fillMaxHeight()) }
                    }
                }
            }
        }
    }

    @Composable
    private fun Pad(kind: EventKind, modifier: Modifier) {
        val justSent = lastTag == kind
        val count = sentCounts[kind] ?: 0
        Box(
            modifier
                .background(if (justSent) kind.tint else Color.White.copy(alpha = 0.09f), RoundedCornerShape(14.dp))
                .border(1.dp, if (justSent) Color.Transparent else kind.tint.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
                .clickable(enabled = hostRecording) { tag(kind) },
            contentAlignment = Alignment.Center,
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(kind.label, color = if (justSent) Color.Black else Color.White, style = MaterialTheme.typography.titleLarge)
                Text(if (count > 0) "$count" else " ", color = if (justSent) Color.Black.copy(alpha = 0.7f) else Color(0xFFB0B4BD))
            }
        }
    }

    private fun tag(kind: EventKind) {
        if (!hostRecording) return
        client?.sendEvent(kind.label)
        sentCounts[kind] = (sentCounts[kind] ?: 0) + 1
        lastTag = kind
        @Suppress("DEPRECATION")
        (getSystemService(Context.VIBRATOR_SERVICE) as? android.os.Vibrator)?.vibrate(
            android.os.VibrationEffect.createOneShot(20, android.os.VibrationEffect.DEFAULT_AMPLITUDE))
        window.decorView.postDelayed({ if (lastTag == kind) lastTag = null }, 700)
    }

    @Composable
    private fun Chip(text: String, background: Color, foreground: Color = Color.White) {
        Box(Modifier.background(background, RoundedCornerShape(17.dp)).padding(horizontal = 12.dp, vertical = 8.dp)) { Text(text, color = foreground, maxLines = 1) }
    }

    private fun timecode(seconds: Double) = "%d:%02d".format(seconds.toInt() / 60, seconds.toInt() % 60)
}
