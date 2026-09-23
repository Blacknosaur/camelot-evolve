import { AudioBufferSink } from "mediabunny";
import type { Recording } from "@/domain";
import { mediaStore } from "@/storage/media-store";
import { openInput } from "./probe";

/* OWNER: media agent. Waveform helpers. mediabunny decodes audio through WebCodecs AudioDecoder and
   returns Web Audio `AudioBuffer`s, which only exist on the main thread — call these from the UI,
   not from a worker. Decoding a short segment is cheap (a few ms of CPU per second of audio). */

/** Decodes [start, end] seconds of the primary audio track into one AudioBuffer, or null when there is no decodable audio. */
export async function extractAudioSegment(source: Pick<Recording, "localPath"> | Blob, start: number, end: number): Promise<AudioBuffer | null> {
  if (typeof AudioBuffer === "undefined" || typeof AudioDecoder === "undefined") return null;
  const file = source instanceof Blob ? source : await (await mediaStore()).read("Recordings", source.localPath);
  if (!file) return null;
  const input = openInput(file);
  try {
    const track = await input.getPrimaryAudioTrack();
    if (!track || !(await track.canDecode())) return null;
    const sink = new AudioBufferSink(track);
    const parts: AudioBuffer[] = [];
    for await (const { buffer } of sink.buffers(Math.max(0, start), Math.max(start, end))) parts.push(buffer);
    return parts.length ? concat(parts) : null;
  } finally {
    input.dispose();
  }
}

/** Per-bucket peak amplitude (0..1) for drawing a waveform strip of `buckets` bars. */
export function waveformPeaks(buffer: AudioBuffer, buckets: number): Float32Array {
  const peaks = new Float32Array(Math.max(1, buckets));
  const perBucket = buffer.length / peaks.length;
  for (let channel = 0; channel < buffer.numberOfChannels; channel++) {
    const data = buffer.getChannelData(channel);
    for (let b = 0; b < peaks.length; b++) {
      const from = Math.floor(b * perBucket), to = Math.min(data.length, Math.floor((b + 1) * perBucket));
      let peak = 0;
      for (let i = from; i < to; i++) { const v = Math.abs(data[i] ?? 0); if (v > peak) peak = v; }
      if (peak > (peaks[b] ?? 0)) peaks[b] = peak;
    }
  }
  return peaks;
}

function concat(parts: AudioBuffer[]): AudioBuffer {
  const first = parts[0]!;
  if (parts.length === 1) return first;
  const length = parts.reduce((n, p) => n + p.length, 0);
  const out = new AudioBuffer({ length, numberOfChannels: first.numberOfChannels, sampleRate: first.sampleRate });
  for (let channel = 0; channel < out.numberOfChannels; channel++) {
    let offset = 0;
    for (const part of parts) { out.copyToChannel(part.getChannelData(Math.min(channel, part.numberOfChannels - 1)), channel, offset); offset += part.length; }
  }
  return out;
}
