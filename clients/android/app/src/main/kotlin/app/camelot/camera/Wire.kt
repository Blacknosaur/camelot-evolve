package app.camelot.camera

import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/**
 * The bytes both sides agree on. Mirrors `MultiCamProtocol.swift`: each socket frame is a 4-byte
 * big-endian length, then a body whose first byte says what follows.
 */
object Wire {
    const val CONTROL: Byte = 1
    const val VIDEO: Byte = 2
    const val FILE_CHUNK: Byte = 3

    /** Swift's Codable enum layout: `{"caseName": {associated values}}`. */
    fun control(name: String, body: JSONObject = JSONObject()): ByteArray {
        val json = JSONObject().put(name, body).toString().toByteArray(Charsets.UTF_8)
        return byteArrayOf(CONTROL) + json
    }

    /** Returns the case name and its payload, or null for anything that is not control JSON. */
    fun decodeControl(body: ByteArray): Pair<String, JSONObject>? {
        if (body.isEmpty() || body[0] != CONTROL) return null
        val json = JSONObject(String(body, 1, body.size - 1, Charsets.UTF_8))
        val name = json.keys().asSequence().firstOrNull() ?: return null
        return name to json.optJSONObject(name).let { it ?: JSONObject() }
    }

    /**
     * One H.264 access unit: `[2][flags][pts f64][count u8]([u16 len][set])*[avcc payload]`.
     * Keyframes carry SPS/PPS so the host can join at any point.
     */
    fun videoPacket(presentationHostTime: Double, isKeyframe: Boolean, parameterSets: List<ByteArray>, payload: ByteBuffer): ByteArray {
        val setsSize = parameterSets.sumOf { 2 + it.size }
        val buffer = ByteBuffer.allocate(1 + 1 + 8 + 1 + setsSize + payload.remaining()).order(ByteOrder.BIG_ENDIAN)
        buffer.put(VIDEO).put(if (isKeyframe) 1 else 0).putDouble(presentationHostTime).put(parameterSets.size.toByte())
        for (set in parameterSets) buffer.putShort(set.size.toShort()).put(set)
        buffer.put(payload)
        return buffer.array()
    }

    /** `[3][16-byte UUID][bytes]`; the host completes the file at the size announced in `transferReady`. */
    fun fileChunk(recordingID: UUID, bytes: ByteArray, length: Int): ByteArray {
        val buffer = ByteBuffer.allocate(1 + 16 + length).order(ByteOrder.BIG_ENDIAN)
        buffer.put(FILE_CHUNK).putLong(recordingID.mostSignificantBits).putLong(recordingID.leastSignificantBits).put(bytes, 0, length)
        return buffer.array()
    }

    /** Annex B (start codes) → AVCC (4-byte lengths), which is what VideoToolbox expects. */
    fun annexBToAvcc(annexB: ByteBuffer): ByteBuffer {
        val nalUnits = splitNalUnits(annexB)
        val out = ByteBuffer.allocate(nalUnits.sumOf { 4 + it.size })
        for (nal in nalUnits) out.putInt(nal.size).put(nal)
        out.flip()
        return out
    }

    fun splitNalUnits(annexB: ByteBuffer): List<ByteArray> {
        val data = ByteArray(annexB.remaining()).also { annexB.duplicate().get(it) }
        val starts = ArrayList<Int>()
        var i = 0
        while (i + 3 <= data.size) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 1.toByte()) { starts.add(i + 3); i += 3 }
            else i++
        }
        val units = ArrayList<ByteArray>()
        for ((index, start) in starts.withIndex()) {
            var end = if (index + 1 < starts.size) starts[index + 1] - 3 else data.size
            while (end > start && data[end - 1] == 0.toByte()) end-- // trailing zero of a 4-byte start code
            if (end > start) units.add(data.copyOfRange(start, end))
        }
        return units
    }
}

/** NTP-style offset: `hostTime = localTime + offset`; the shortest round trips are trusted most. */
class ClockSync(private val keeps: Int = 8) {
    private data class Sample(val offset: Double, val roundTrip: Double)
    private val samples = ArrayList<Sample>()

    val isSynced: Boolean get() = samples.isNotEmpty()
    val offset: Double get() = if (samples.isEmpty()) 0.0 else samples.map { it.offset }.sorted()[samples.size / 2]
    val uncertainty: Double get() = (samples.minOfOrNull { it.roundTrip } ?: 0.0) / 2

    @Synchronized
    fun record(sentAt: Double, hostReceivedAt: Double, hostSentAt: Double, receivedAt: Double) {
        val roundTrip = (receivedAt - sentAt) - (hostSentAt - hostReceivedAt)
        if (roundTrip < 0) return
        samples.add(Sample(((hostReceivedAt - sentAt) + (hostSentAt - receivedAt)) / 2, roundTrip))
        samples.sortBy { it.roundTrip }
        while (samples.size > keeps) samples.removeAt(samples.size - 1)
    }

    fun hostTime(local: Double) = local + offset

    companion object {
        /** Seconds on the monotonic clock. */
        fun localNow(): Double = System.nanoTime() / 1e9
    }
}
