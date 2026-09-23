package app.camelot.camera

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

data class DiscoveredHost(val name: String, val address: java.net.InetAddress, val port: Int, val project: String, val mode: String)

/** Everything the UI needs to know about the link; mutated on the main thread only. */
interface SessionListener {
    fun onHosts(hosts: List<DiscoveredHost>)
    fun onConnected(hostName: String, projectName: String, projectID: UUID, mode: String)
    fun onDisconnected(reason: String)
    fun onHostStatus(isRecording: Boolean, elapsedSeconds: Double)
    fun onStartRecording(recordingID: UUID)
    fun onStopRecording()
    fun onTransferReceived(recordingID: UUID)
    fun onClock(synced: Boolean, uncertaintyMs: Double)
}

/**
 * Finds the iOS host over NSD, then talks to it over one TCP socket. Sends are serialized on one
 * thread so a video packet never lands in the middle of a file chunk.
 */
class SessionClient(context: Context, private val deviceName: String, private val deviceID: UUID, private val listener: SessionListener) {
    val clock = ClockSync()
    private val main = Handler(Looper.getMainLooper())
    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    /** Android needs a multicast lock for mDNS; without it discovery can go silent on some ROMs. */
    private val multicastLock = (appContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager)
        .createMulticastLock("camelot-discovery").apply { setReferenceCounted(false) }
    /** Set once a service is seen, so the watchdog knows discovery is actually alive. */
    @Volatile var hasDiscovered = false; private set
    private val writer = Executors.newSingleThreadExecutor()
    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    private val closed = AtomicBoolean(false)
    private val hosts = LinkedHashMap<String, DiscoveredHost>()
    private var discovery: NsdManager.DiscoveryListener? = null
    var hostName = ""; private set
    var projectID: UUID? = null; private set

    // MARK: Discovery

    fun startBrowsing() {
        if (discovery != null) return
        runCatching { multicastLock.acquire() }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "discovery failed to start: $errorCode")
                discovery = null
                runCatching { nsd.stopServiceDiscovery(this) }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "discovery failed to stop: $errorCode"); discovery = null }
            override fun onDiscoveryStarted(serviceType: String) { Log.i(TAG, "discovery started") }
            override fun onDiscoveryStopped(serviceType: String) { Log.i(TAG, "discovery stopped"); discovery = null }
            override fun onServiceFound(service: NsdServiceInfo) { hasDiscovered = true; Log.i(TAG, "found ${service.serviceName}"); resolve(service) }
            override fun onServiceLost(service: NsdServiceInfo) {
                main.post { hosts.remove(service.serviceName); this@SessionClient.listener.onHosts(hosts.values.toList()) }
            }
        }
        discovery = listener
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, listener)
    }

    private fun resolve(service: NsdServiceInfo) {
        nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { Log.w(TAG, "resolve failed $errorCode") }
            override fun onServiceResolved(info: NsdServiceInfo) {
                val txt = info.attributes.mapValues { String(it.value ?: ByteArray(0), Charsets.UTF_8) }
                val address = info.host
                Log.i(TAG, "resolved ${info.serviceName} at $address:${info.port} txt=$txt")
                if (address == null) return
                val host = DiscoveredHost(info.serviceName, address, info.port, txt["project"] ?: "", txt["mode"] ?: "")
                // Prefer an IPv4 answer when the same host resolves twice (Wi‑Fi and peer-to-peer).
                main.post {
                    val existing = hosts[info.serviceName]
                    if (existing == null || existing.address is java.net.Inet6Address) hosts[info.serviceName] = host
                    listener.onHosts(hosts.values.toList())
                }
            }
        })
    }

    fun stopBrowsing() {
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        runCatching { multicastLock.release() }
    }

    /** Tears the listener down and starts a fresh one; NsdManager can go silent after a restart. */
    fun restartBrowsing() {
        Log.i(TAG, "restarting discovery")
        stopBrowsing()
        main.postDelayed({ if (!closed.get()) startBrowsing() }, 600)
    }

    // MARK: Connection

    /** "192.168.1.40:53084" (or just the IP) typed by hand when the network blocks Bonjour. */
    fun connectManually(text: String, defaultPort: Int = 0): Boolean {
        val trimmed = text.trim()
        val host = trimmed.substringBefore(':')
        val port = trimmed.substringAfter(':', "").toIntOrNull() ?: defaultPort
        if (host.isEmpty() || port <= 0) return false
        stopBrowsing()
        connect(DiscoveredHost(host, java.net.InetSocketAddress(host, port).address ?: return false, port, "", ""))
        return true
    }

    fun connect(host: DiscoveredHost) {
        hostName = host.name
        Thread({
            try {
                Log.i(TAG, "connecting to ${host.address}:${host.port}")
                val socket = Socket().apply { tcpNoDelay = true; connect(InetSocketAddress(host.address, host.port), 8_000) }
                this.socket = socket
                output = DataOutputStream(socket.getOutputStream().buffered(256 * 1024))
                send(Wire.control("hello", JSONObject().put("deviceName", deviceName).put("deviceID", deviceID.toString().uppercase())))
                readLoop(DataInputStream(socket.getInputStream().buffered(64 * 1024)))
            } catch (error: Exception) {
                if (!closed.get()) main.post { listener.onDisconnected(error.message ?: "Connection failed") }
            }
        }, "camelot-reader").start()
    }

    private fun readLoop(input: DataInputStream) {
        while (!closed.get()) {
            val length = input.readInt()
            if (length <= 0 || length > 64 * 1024 * 1024) throw IllegalStateException("Bad frame length $length")
            val body = ByteArray(length)
            input.readFully(body)
            val (name, payload) = Wire.decodeControl(body) ?: continue
            handle(name, payload)
        }
    }

    private fun handle(name: String, payload: JSONObject) {
        when (name) {
            "welcome" -> {
                projectID = UUID.fromString(payload.getString("projectID"))
                val hostName = payload.optString("hostName", hostName).also { this.hostName = it }
                val projectName = payload.optString("projectName", "")
                val mode = payload.optString("mode", "")
                main.post { listener.onConnected(hostName, projectName, projectID!!, mode) }
                startClockSync()
            }
            "clockPong" -> {
                val id = payload.getString("id")
                val sentAt = pendingPings.remove(id) ?: return
                clock.record(sentAt, payload.getDouble("hostReceivedAt"), payload.getDouble("hostSentAt"), ClockSync.localNow())
                main.post { listener.onClock(true, clock.uncertainty * 1000) }
            }
            "hostStatus" -> main.post { listener.onHostStatus(payload.getBoolean("isRecording"), payload.getDouble("elapsedSeconds")) }
            "startRecording" -> main.post { Log.i(TAG, "host: start recording"); listener.onStartRecording(UUID.fromString(payload.getString("recordingID"))) }
            "stopRecording" -> main.post { Log.i(TAG, "host: stop recording"); listener.onStopRecording() }
            "transferReceived" -> main.post { listener.onTransferReceived(UUID.fromString(payload.getString("recordingID"))) }
            "endSession" -> { close(); main.post { listener.onDisconnected("$hostName ended the session.") } }
        }
    }

    private val pendingPings = java.util.concurrent.ConcurrentHashMap<String, Double>()

    private fun startClockSync() {
        Thread({
            var round = 0
            while (!closed.get()) {
                val id = UUID.randomUUID().toString().uppercase()
                val now = ClockSync.localNow()
                pendingPings[id] = now
                send(Wire.control("clockPing", JSONObject().put("id", id).put("sentAt", now)))
                round += 1
                Thread.sleep(if (round < 10) 500 else 10_000)
            }
        }, "camelot-clock").start()
    }

    fun hostNow(): Double = clock.hostTime(ClockSync.localNow())

    // MARK: Sending

    fun send(body: ByteArray) {
        if (closed.get()) return
        writer.execute {
            try {
                val output = output ?: return@execute
                output.writeInt(body.size)
                output.write(body)
                output.flush()
            } catch (error: Exception) {
                if (!closed.get()) { close(); main.post { listener.onDisconnected(error.message ?: "Connection lost") } }
            }
        }
    }

    fun sendStatus(isRecording: Boolean, elapsedSeconds: Double, batteryLevel: Float, freeMegabytes: Int) {
        send(Wire.control("cameraStatus", JSONObject().put("isRecording", isRecording).put("elapsedSeconds", elapsedSeconds)
            .put("batteryLevel", batteryLevel).put("freeMegabytes", freeMegabytes)))
    }

    /** A tap on the event pad, stamped with the host's clock so it lands at the right second. */
    fun sendEvent(kind: String) {
        send(Wire.control("event", JSONObject().put("kind", kind).put("hostTime", hostNow())))
    }

    fun sendRecordingStarted(recordingID: UUID, firstFrameHostTime: Double) {
        send(Wire.control("recordingStarted", JSONObject().put("recordingID", recordingID.toString().uppercase()).put("firstFrameHostTime", firstFrameHostTime)))
    }

    /** Announces the file, then streams it in chunks on the writer thread; `progress` is 0…1. */
    fun sendFile(recordingID: UUID, file: File, durationSeconds: Double, firstFrameHostTime: Double, progress: (Double) -> Unit) {
        val size = file.length()
        Log.i(TAG, "sending ${file.name}: $size bytes")
        send(Wire.control("transferReady", JSONObject().put("recordingID", recordingID.toString().uppercase()).put("byteCount", size)
            .put("durationSeconds", durationSeconds).put("firstFrameHostTime", firstFrameHostTime).put("deviceName", deviceName)))
        writer.execute {
            try {
                val output = output ?: return@execute
                file.inputStream().buffered(CHUNK).use { input ->
                    val buffer = ByteArray(CHUNK)
                    var sent = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        val body = Wire.fileChunk(recordingID, buffer, read)
                        output.writeInt(body.size); output.write(body)
                        sent += read
                        val fraction = sent.toDouble() / size
                        main.post { progress(fraction) }
                    }
                    output.flush()
                    Log.i(TAG, "sent ${file.name}")
                }
            } catch (error: Exception) {
                Log.w(TAG, "transfer failed", error)
                if (!closed.get()) { close(); main.post { listener.onDisconnected(error.message ?: "Transfer failed") } }
            }
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        stopBrowsing()
        runCatching { socket?.close() }
        writer.shutdown()
    }

    companion object {
        const val SERVICE_TYPE = "_camelot-sock._tcp"
        private const val TAG = "SessionClient"
        private const val CHUNK = 256 * 1024
    }
}
