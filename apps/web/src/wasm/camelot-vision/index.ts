/* Loader for the Rust kernels (crates/camelot-vision → wasm-bindgen, `--target web`). The generated files land
   in `./pkg`. Callers use `visionKernels()`: null until `loadVisionKernels()` resolved, so every algorithm keeps
   its TypeScript path and simply gets faster once the module is in memory. */

export interface VisionKernels {
  version(): string;
  /** Harris-style corners with spatial quotas; flat `[x0, y0, x1, y1, …]` in image pixels. */
  corners(values: Float32Array, width: number, height: number): Float32Array;
  /** Coarse-to-fine SAD translation of `previous` content in `current`, `[dx, dy]` pixels, or null. */
  translation(previous: Float32Array, current: Float32Array, width: number, height: number, maximumFraction: number): Float32Array | null;
  /** 15-bin hue/neutral kit histogram of RGB triples (0…1). */
  jerseyHistogram(colors: Float32Array): Float32Array;
  /** Bhattacharyya coefficient of two histograms. */
  histogramSimilarity(a: Float32Array, b: Float32Array): number;
  /** Whiteness (0…255) and turf (0/1) maps for pitch marking evidence. */
  markingEvidence(rgba: Uint8Array | Uint8ClampedArray, width: number, height: number): { whiteness: Uint8Array; turf: Uint8Array };
  /** Hough line segments over marking candidates; flat `[x0, y0, x1, y1, …]` normalized to the image. */
  houghSegments(rgba: Uint8Array | Uint8ClampedArray, width: number, height: number): Float32Array;
  /** Least-squares homography (h33 = 1) from `[x, y, u, v, …]` correspondences, or null when degenerate. */
  fitHomography(matches: Float64Array): Float64Array | null;
}

let kernels: VisionKernels | null = null;
let loading: Promise<VisionKernels | null> | null = null;

export function visionKernels(): VisionKernels | null { return kernels; }

/** Loads the WASM module once; resolves null (and logs) when the build is missing or the platform lacks WebAssembly. */
export function loadVisionKernels(): Promise<VisionKernels | null> {
  loading ??= (async () => {
    if (typeof WebAssembly === "undefined") return null;
    try {
      // `import.meta.glob` tolerates a missing build: the map is simply empty until `pnpm wasm` has run.
      const builds = import.meta.glob<WasmModule>("./pkg/camelot_vision.js");
      const load = builds["./pkg/camelot_vision.js"];
      if (!load) return null;
      const module = await load();
      await module.default();
      kernels = wrap(module);
      return kernels;
    } catch (error) {
      console.info("camelot-vision WASM unavailable; using TypeScript kernels.", error);
      return null;
    }
  })();
  return loading;
}

/** Test hook: install fake kernels or clear them. */
export function setVisionKernels(next: VisionKernels | null) { kernels = next; loading = null; }

interface WasmModule {
  default(input?: unknown): Promise<unknown>;
  version(): string;
  corners(values: Float32Array, width: number, height: number): Float32Array;
  translation(previous: Float32Array, current: Float32Array, width: number, height: number, maximum_fraction: number): Float32Array;
  jersey_histogram(colors: Float32Array): Float32Array;
  histogram_similarity(a: Float32Array, b: Float32Array): number;
  marking_evidence(rgba: Uint8Array, width: number, height: number): Uint8Array;
  hough_segments(rgba: Uint8Array, width: number, height: number): Float32Array;
  fit_homography(matches: Float64Array): Float64Array;
}

function wrap(module: WasmModule): VisionKernels {
  return {
    version: () => module.version(),
    corners: (values, width, height) => module.corners(values, width, height),
    translation: (previous, current, width, height, maximumFraction) => {
      const result = module.translation(previous, current, width, height, maximumFraction);
      return result.length === 2 ? result : null;
    },
    jerseyHistogram: (colors) => module.jersey_histogram(colors),
    histogramSimilarity: (a, b) => module.histogram_similarity(a, b),
    markingEvidence: (rgba, width, height) => {
      const packed = module.marking_evidence(rgba instanceof Uint8Array ? rgba : new Uint8Array(rgba.buffer, rgba.byteOffset, rgba.byteLength), width, height);
      const n = width * height;
      return { whiteness: packed.subarray(0, n), turf: packed.subarray(n, 2 * n) };
    },
    houghSegments: (rgba, width, height) => module.hough_segments(rgba instanceof Uint8Array ? rgba : new Uint8Array(rgba.buffer, rgba.byteOffset, rgba.byteLength), width, height),
    fitHomography: (matches) => { const result = module.fit_homography(matches); return result.length === 9 ? result : null; },
  };
}
