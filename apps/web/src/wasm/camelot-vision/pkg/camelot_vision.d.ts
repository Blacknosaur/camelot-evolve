/* tslint:disable */
/* eslint-disable */

/**
 * Harris-style corners of a luma image (0…1 floats) with equal spatial quotas: 8×6 cells, 3 per cell, skipping the
 * bottom tenth. Returns flat `[x0, y0, x1, y1, …]` pixel coordinates.
 */
export function corners(values: Float32Array, width: number, height: number): Float32Array;

/**
 * Least-squares homography (h33 = 1) from `[x, y, u, v, …]` correspondences with pivoted elimination. Empty when
 * degenerate.
 */
export function fit_homography(matches: Float64Array): Float64Array;

/**
 * Bhattacharyya coefficient of two normalized histograms.
 */
export function histogram_similarity(a: Float32Array, b: Float32Array): number;

/**
 * Straight white marking segments with turf on both sides. Input is RGBA at working resolution (≤640 wide);
 * output is flat `[x0, y0, x1, y1, …]` normalized to the image, at most 8 segments.
 */
export function hough_segments(rgba: Uint8Array, width: number, height: number): Float32Array;

/**
 * 15-bin hue/neutral histogram of RGB triples in 0…1 (12 hue bins + 3 neutral brightness bins), normalized.
 */
export function jersey_histogram(colors: Float32Array): Float32Array;

/**
 * Whiteness (0…255) followed by turf (0/1) maps, each `width * height` bytes, packed into one buffer.
 */
export function marking_evidence(rgba: Uint8Array, width: number, height: number): Uint8Array;

/**
 * Converts RGBA8 to a single-channel luma buffer (BT.601 weights).
 */
export function rgba_to_luma(rgba: Uint8Array, width: number, height: number): Uint8Array;

/**
 * Coarse-to-fine SAD block matching of `previous` in `current` (same size luma images). Returns `[dx, dy]` pixels, or
 * an empty vector when nothing could be compared.
 */
export function translation(previous: Float32Array, current: Float32Array, width: number, height: number, maximum_fraction: number): Float32Array;

/**
 * Sanity export used by the worker to confirm the module loaded.
 */
export function version(): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly corners: (a: number, b: number, c: number, d: number) => [number, number];
    readonly fit_homography: (a: number, b: number) => [number, number];
    readonly histogram_similarity: (a: number, b: number, c: number, d: number) => number;
    readonly hough_segments: (a: number, b: number, c: number, d: number) => [number, number];
    readonly jersey_histogram: (a: number, b: number) => [number, number];
    readonly marking_evidence: (a: number, b: number, c: number, d: number) => [number, number];
    readonly rgba_to_luma: (a: number, b: number, c: number, d: number) => [number, number];
    readonly translation: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => [number, number];
    readonly version: () => [number, number];
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
