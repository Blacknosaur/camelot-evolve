/* Parity of the Rust kernels with their TypeScript fallbacks. Skipped when the WASM package has not been built
   (`pnpm --filter @camelot/web wasm`). Runs the module from disk, so it also proves the build loads. */
import { readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { RGB } from "@/features/analysis/tracking/frame-pixels";
import { signatureFromColors, signatureSimilarity } from "@/features/analysis/tracking/identity";
import { fitHomography } from "@/features/analysis/tracking/camera-registration";

// vitest runs with the package as cwd; import.meta.url is an http URL under jsdom, so resolve from disk.
const wasmPath = path.resolve(process.cwd(), "src/wasm/camelot-vision/pkg/camelot_vision_bg.wasm");
const built = existsSync(wasmPath);

describe.skipIf(!built)("camelot-vision WASM", () => {
  async function load() {
    const module = await import("./pkg/camelot_vision.js");
    await module.default({ module_or_path: await readFile(wasmPath) });
    return module;
  }

  it("loads and reports its version", async () => {
    const module = await load();
    expect(module.version()).toBe("0.0.0");
  });

  it("jersey histograms match the TypeScript signature", async () => {
    const module = await load();
    const colors: RGB[] = Array.from({ length: 120 }, (_, i) => [0.08 + (i % 7) * 0.01, 0.72 - (i % 5) * 0.02, 0.18]);
    const ts = signatureFromColors(colors).bins;
    const rust = Array.from(module.jersey_histogram(new Float32Array(colors.flat())));
    rust.forEach((v, i) => expect(v).toBeCloseTo(ts[i]!, 5));
    expect(module.histogram_similarity(new Float32Array(ts), new Float32Array(rust))).toBeCloseTo(signatureSimilarity({ bins: ts }, { bins: rust }), 5);
  });

  it("homography fitting matches the TypeScript solver", async () => {
    const module = await load();
    const matches = [{ x: 0.1, y: 0.1 }, { x: 0.9, y: 0.1 }, { x: 0.9, y: 0.9 }, { x: 0.1, y: 0.9 }, { x: 0.5, y: 0.3 }].map((p) => ({ source: p, target: { x: p.x * 1.05 + 0.02, y: p.y * 0.98 - 0.01 } }));
    const ts = fitHomography(matches)!.values;
    const rust = Array.from(module.fit_homography(new Float64Array(matches.flatMap((m) => [m.source.x, m.source.y, m.target.x, m.target.y]))));
    expect(rust).toHaveLength(9);
    rust.forEach((v, i) => expect(v).toBeCloseTo(ts[i]!, 8));
  });

  it("marking evidence flags paint and turf like the TypeScript evidence", async () => {
    const module = await load();
    const out = module.marking_evidence(new Uint8Array([250, 250, 250, 255, 40, 140, 40, 255]), 2, 1);
    expect(out[0]).toBeGreaterThan(200);
    expect(out[1]).toBe(0);
    expect(out[3]).toBe(1);
  });
});
