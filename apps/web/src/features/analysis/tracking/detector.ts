/* Body detection, appearance prints and shirt-number reading behind small interfaces so the tracking loops stay
   free of vendor code. iOS uses a bundled sports CoreML detector, VNGenerateImageFeaturePrintRequest and
   VNRecognizeTextRequest; on the web the detector is MediaPipe Tasks Vision's ObjectDetector (EfficientDet-Lite0,
   "person" class) and the print is its ImageEmbedder (MobileNet V3 small), both loaded from the CDN inside the
   worker. Shirt-number OCR has no browser counterpart yet: `ShirtNumberReader` is the extension point. */
import type { Rect } from "@/domain/geometry";
import { cropRegion, type FramePixels } from "./frame-pixels";
import { insetRect, intersectRects, overlap, UNIT_RECT } from "./geometry";

export interface BodyDetector {
  /** Full-body boxes (fractions of the frame), de-duplicated at IoU > 0.5. `region` restricts the search. */
  playerBoxes(frame: FramePixels, region?: Rect): Promise<Rect[]>;
  close(): void;
}

export interface AppearancePrinter {
  print(frame: FramePixels, box: Rect): Promise<number[] | null>;
  close(): void;
}

export interface ShirtNumberReader {
  read(frame: FramePixels, box: Rect): Promise<string | null>;
  close(): void;
}

export interface VisionCapabilities {
  detector: boolean;
  printer: boolean;
  numbers: boolean;
  reason?: string;
}

const TASKS_VISION_VERSION = "0.10.35";
const WASM_ROOT = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${TASKS_VISION_VERSION}/wasm`;
const DETECTOR_MODEL = "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float16/latest/efficientdet_lite0.tflite";
const EMBEDDER_MODEL = "https://storage.googleapis.com/mediapipe-models/image_embedder/mobilenet_v3_small/float32/latest/mobilenet_v3_small.tflite";

/** iOS confidence floor for the sports detector; EfficientDet person scores are comparable in practice. */
const MINIMUM_CONFIDENCE = 0.22;
const DETECTOR_INPUT = 320;

type Vision = typeof import("@mediapipe/tasks-vision");
let visionModule: Promise<Vision> | null = null;
let fileset: Promise<unknown> | null = null;

function loadVision(): Promise<Vision> {
  visionModule ??= import("@mediapipe/tasks-vision");
  return visionModule;
}
async function loadFileset(): Promise<unknown> {
  const vision = await loadVision();
  fileset ??= vision.FilesetResolver.forVisionTasks(WASM_ROOT);
  return fileset;
}

export function visionCapabilities(): VisionCapabilities {
  const supported = typeof WebAssembly !== "undefined" && typeof OffscreenCanvas !== "undefined" && typeof fetch !== "undefined";
  return { detector: supported, printer: supported, numbers: false, reason: supported ? undefined : "WebAssembly, OffscreenCanvas or fetch is unavailable" };
}

function toImageData(frame: FramePixels): ImageData {
  const data = frame.data instanceof Uint8ClampedArray ? frame.data : new Uint8ClampedArray(frame.data.buffer, frame.data.byteOffset, frame.data.byteLength);
  return new ImageData(data as Uint8ClampedArray<ArrayBuffer>, frame.width, frame.height);
}

/** MediaPipe ObjectDetector limited to people; runs on two overlapping halves like the iOS sports detector. */
export async function createBodyDetector(): Promise<BodyDetector> {
  const vision = await loadVision();
  const options = (delegate: "GPU" | "CPU") => ({
    baseOptions: { modelAssetPath: DETECTOR_MODEL, delegate },
    runningMode: "IMAGE" as const, scoreThreshold: MINIMUM_CONFIDENCE, categoryAllowlist: ["person"], maxResults: 40,
  });
  const detector = await vision.ObjectDetector.createFromOptions((await loadFileset()) as never, options("GPU"))
    .catch(async () => vision.ObjectDetector.createFromOptions((await loadFileset()) as never, options("CPU")));
  return {
    async playerBoxes(frame, region) {
      const regions = region ? [region] : [{ x: 0, y: 0, width: 0.6, height: 1 }, { x: 0.4, y: 0, width: 0.6, height: 1 }];
      const boxes: [Rect, number][] = [];
      for (const r of regions) {
        const aspect = (r.width * frame.width) / Math.max(1, r.height * frame.height);
        const w = aspect >= 1 ? DETECTOR_INPUT : Math.max(64, Math.round(DETECTOR_INPUT * aspect));
        const h = aspect >= 1 ? Math.max(64, Math.round(DETECTOR_INPUT / aspect)) : DETECTOR_INPUT;
        const crop = cropRegion(frame, r, w, h);
        const result = detector.detect(toImageData(crop));
        for (const detection of result.detections) {
          const category = detection.categories[0];
          const bb = detection.boundingBox;
          if (!category || !bb || category.score < MINIMUM_CONFIDENCE) continue;
          boxes.push([{ x: r.x + (bb.originX / w) * r.width, y: r.y + (bb.originY / h) * r.height, width: (bb.width / w) * r.width, height: (bb.height / h) * r.height }, category.score]);
        }
      }
      const kept: [Rect, number][] = [];
      for (const candidate of boxes.sort((a, b) => b[1] - a[1])) if (!kept.some((k) => overlap(k[0], candidate[0]) > 0.5)) kept.push(candidate);
      return kept.map((k) => k[0]);
    },
    close() { detector.close(); },
  };
}

/** MediaPipe ImageEmbedder of a padded body crop (the iOS feature print equivalent). */
export async function createAppearancePrinter(): Promise<AppearancePrinter> {
  const vision = await loadVision();
  const options = (delegate: "GPU" | "CPU") => ({ baseOptions: { modelAssetPath: EMBEDDER_MODEL, delegate }, runningMode: "IMAGE" as const, l2Normalize: true });
  const embedder = await vision.ImageEmbedder.createFromOptions((await loadFileset()) as never, options("GPU"))
    .catch(async () => vision.ImageEmbedder.createFromOptions((await loadFileset()) as never, options("CPU")));
  return {
    async print(frame, box) {
      const padded = intersectRects(insetRect(box, -box.width * 0.1, -box.height * 0.04), UNIT_RECT);
      if (!padded || padded.width <= 0.004 || padded.height <= 0.01) return null;
      const crop = cropRegion(frame, padded, 128, 256);
      const embedding = embedder.embed(toImageData(crop)).embeddings[0]?.floatEmbedding;
      return embedding ? Array.from(embedding) : null;
    },
    close() { embedder.close(); },
  };
}

/** No OCR in the browser yet: numbers are never read, so identities rely on kit, tone and prints. */
export const nullShirtNumberReader: ShirtNumberReader = { read: async () => null, close() {} };

/** Detector used when the model cannot load: tracking continues optically, recovery and rosters are unavailable. */
export const nullBodyDetector: BodyDetector = { playerBoxes: async () => [], close() {} };
export const nullAppearancePrinter: AppearancePrinter = { print: async () => null, close() {} };

export interface VisionModels { detector: BodyDetector; printer: AppearancePrinter; numbers: ShirtNumberReader; detectorAvailable: boolean }

let models: Promise<VisionModels> | null = null;

/** Loads the detector and embedder once per worker, falling back to no-op implementations. */
export function loadVisionModels(): Promise<VisionModels> {
  models ??= (async () => {
    const capabilities = visionCapabilities();
    if (!capabilities.detector) return { detector: nullBodyDetector, printer: nullAppearancePrinter, numbers: nullShirtNumberReader, detectorAvailable: false };
    let detector = nullBodyDetector, detectorAvailable = false;
    try { detector = await createBodyDetector(); detectorAvailable = true; } catch (error) { console.warn("Body detector unavailable", error); }
    let printer = nullAppearancePrinter;
    try { printer = await createAppearancePrinter(); } catch (error) { console.info("Appearance embedder unavailable", error); }
    return { detector, printer, numbers: nullShirtNumberReader, detectorAvailable };
  })();
  return models;
}
