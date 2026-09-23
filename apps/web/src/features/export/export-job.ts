import type { Recording, VideoComposition } from "@/domain/records";
import { renderRevision } from "@/domain/records";
import { recordings as recordingRepository } from "@/storage/repository";
import { mediaStore } from "@/storage/media-store";
import { WorkerClient } from "@/workers/client";
import { cachedExport, exportSidecarKey, type ExportArtifact, type ExportProgress, type ExportSettings } from "./render";

/* Main-thread side of the export pipeline: resolves recordings, dispatches the render job to the export
   worker and exposes the finished file (object URL / File) for download and Web Share. */

let client: WorkerClient | null = null;
function worker(): WorkerClient {
  client ??= new WorkerClient(new Worker(new URL("../../workers/export.worker.ts", import.meta.url), { type: "module" }));
  return client;
}

export interface ExportHandle {
  result: Promise<ExportArtifact>;
  cancel(): void;
}

/** Cached render for the composition's current manifest and these settings, if any. */
export async function existingExport(composition: Pick<VideoComposition, "id" | "clips" | "aspectRatio">, settings: ExportSettings): Promise<ExportArtifact | null> {
  return cachedExport(await mediaStore(), composition.id, await renderRevision(composition), settings);
}

export function startExport(composition: Pick<VideoComposition, "id" | "name" | "projectID" | "clips" | "aspectRatio">, settings: ExportSettings, onProgress: (p: ExportProgress) => void): ExportHandle {
  let cancelled = false;
  let inner: ExportHandle | null = null;
  const result = (async () => {
    const [revision, all] = await Promise.all([renderRevision(composition), recordingRepository.forProject(composition.projectID)]);
    const needed = new Set(composition.clips.map((clip) => clip.recordingID));
    const recordings: Recording[] = all.filter((r) => needed.has(r.id));
    const missing = [...needed].filter((id) => !recordings.some((r) => r.id === id && r.localPath));
    if (missing.length) throw new Error(missing.length === 1 ? "One clip's recording is not on this device." : `${missing.length} clip recordings are not on this device.`);
    if (cancelled) throw new DOMException("Export cancelled", "AbortError");
    inner = worker().run("export.render", { composition: { id: composition.id, name: composition.name, clips: composition.clips, aspectRatio: composition.aspectRatio }, recordings, settings, revision }, onProgress);
    return inner.result;
  })();
  return { result, cancel: () => { cancelled = true; inner?.cancel(); } };
}

/** Removes a rendered file and its sidecar (port of VideoComposition.invalidateRender). */
export async function invalidateExport(compositionID: string): Promise<void> {
  const store = await mediaStore();
  await Promise.all([store.delete("Exports", `${compositionID}.mp4`), store.delete("Exports", `${compositionID}.webm`), store.delete("Exports", exportSidecarKey(compositionID))]);
}

/** User-facing filename for a download or share ("Goals summary.mp4"). */
export function exportFilename(artifact: ExportArtifact, name: string): string {
  return `${sanitizeFilename(name)}${artifact.key.slice(artifact.key.lastIndexOf("."))}`;
}

export async function exportFile(artifact: ExportArtifact, name: string): Promise<File | null> {
  const file = await (await mediaStore()).read("Exports", artifact.key);
  return file ? new File([file], exportFilename(artifact, name), { type: artifact.mimeType }) : null;
}

export function canShareFiles(): boolean {
  return typeof navigator !== "undefined" && typeof navigator.share === "function" && typeof navigator.canShare === "function";
}

const sanitizeFilename = (name: string) => (name.trim().replace(/[\\/:*?"<>|]+/g, "-") || "Camelot export").slice(0, 80);
