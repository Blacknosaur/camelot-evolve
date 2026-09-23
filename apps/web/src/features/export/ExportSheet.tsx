import { useEffect, useRef, useState } from "react";
import type { VideoComposition } from "@/domain/records";
import { compositionDuration } from "@/domain/records";
import { Button, Spinner } from "@/design/components";
import { Icon } from "@/design/icons";
import { byteCount, compactDuration } from "@/design/format";
import { detectMediaCapabilities } from "@/media/capabilities";
import { mediaStore } from "@/storage/media-store";
import { aspectRatioTitle, type ResolutionPreset } from "./preview-parity";
import { DEFAULT_EXPORT_SETTINGS, type ExportArtifact, type ExportProgress, type ExportSettings, type FpsChoice } from "./render";
import { canShareFiles, existingExport, exportFile, exportFilename, startExport, type ExportHandle } from "./export-job";
import "./ExportSheet.css";

/* Port of the export card in CompositionPlayerView.swift ("Render video" → progress → Share). Adds the
   resolution/fps choices the browser needs because the encoder is the CPU/GPU of whatever device is open. */

type Phase =
  | { kind: "idle" }
  | { kind: "unsupported"; message: string }
  | { kind: "rendering"; progress: ExportProgress }
  | { kind: "done"; artifact: ExportArtifact; cached: boolean }
  | { kind: "error"; message: string };

const RESOLUTIONS: { value: ResolutionPreset; label: string }[] = [{ value: "source", label: "Source" }, { value: "1080p", label: "1080p" }, { value: "720p", label: "720p" }];
const FRAME_RATES: { value: FpsChoice; label: string }[] = [{ value: "source", label: "Source" }, { value: 24, label: "24" }, { value: 30, label: "30" }, { value: 60, label: "60" }];

export function ExportSheet({ composition, onClose }: { composition: VideoComposition; onClose: () => void }) {
  const [settings, setSettings] = useState<ExportSettings>(DEFAULT_EXPORT_SETTINGS);
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  const [shareState, setShareState] = useState<"idle" | "sharing" | "failed">("idle");
  const handle = useRef<ExportHandle | null>(null);
  const objectURL = useRef<string | null>(null);
  const duration = compositionDuration(composition.clips);
  const busy = phase.kind === "rendering";

  useEffect(() => () => { handle.current?.cancel(); if (objectURL.current) URL.revokeObjectURL(objectURL.current); }, []);

  // Capability gate + cache lookup whenever settings change (an existing render for these settings shows immediately).
  useEffect(() => {
    if (busy) return;
    const capabilities = detectMediaCapabilities();
    if (!capabilities.webCodecs) { setPhase({ kind: "unsupported", message: "This browser has no WebCodecs support, so video cannot be rendered here. Use a current Chrome, Edge or Safari." }); return; }
    if (typeof OffscreenCanvas === "undefined") { setPhase({ kind: "unsupported", message: "This browser cannot draw video frames in the background (OffscreenCanvas missing)." }); return; }
    let live = true;
    existingExport(composition, settings).then((artifact) => { if (live) setPhase(artifact ? { kind: "done", artifact, cached: true } : { kind: "idle" }); }, () => { if (live) setPhase({ kind: "idle" }); });
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [composition.id, composition.clips, composition.aspectRatio, settings]);

  const render = () => {
    setPhase({ kind: "rendering", progress: { fraction: 0, stage: "Preparing" } });
    const job = startExport(composition, settings, (progress) => setPhase({ kind: "rendering", progress }));
    handle.current = job;
    job.result.then(
      (artifact) => { handle.current = null; setPhase({ kind: "done", artifact, cached: false }); },
      (error: unknown) => {
        handle.current = null;
        if (error instanceof DOMException && error.name === "AbortError") { setPhase({ kind: "idle" }); return; }
        setPhase({ kind: "error", message: error instanceof Error ? error.message : "The video could not be rendered." });
      },
    );
  };

  const cancel = () => { handle.current?.cancel(); handle.current = null; setPhase({ kind: "idle" }); };

  const download = async (artifact: ExportArtifact) => {
    const url = await (await mediaStore()).url("Exports", artifact.key);
    if (!url) { setPhase({ kind: "error", message: "The rendered file is missing. Render it again." }); return; }
    if (objectURL.current) URL.revokeObjectURL(objectURL.current);
    objectURL.current = url;
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = exportFilename(artifact, composition.name);
    anchor.click();
  };

  const share = async (artifact: ExportArtifact) => {
    const file = await exportFile(artifact, composition.name);
    if (!file || !navigator.canShare?.({ files: [file] })) { setShareState("failed"); return; }
    setShareState("sharing");
    try { await navigator.share({ files: [file], title: composition.name }); setShareState("idle"); }
    catch (error) { setShareState(error instanceof DOMException && error.name === "AbortError" ? "idle" : "failed"); }
  };

  return (
    <div className="export-backdrop" data-surface="dark" role="presentation" onClick={(event) => { if (event.target === event.currentTarget && !busy) onClose(); }}>
      <section className="export-sheet" role="dialog" aria-modal="true" aria-labelledby="export-title">
        <header className="export-header">
          <div>
            <h2 id="export-title">Export video</h2>
            <p className="export-meta tabular">{compactDuration(duration)} · {composition.clips.length} {composition.clips.length === 1 ? "clip" : "clips"} · {aspectRatioTitle(composition.aspectRatio)}</p>
          </div>
          <Button variant="pill" aria-label="Close" onClick={onClose} disabled={busy}><Icon.Close /></Button>
        </header>

        {phase.kind === "unsupported" ? (
          <Notice icon={<Icon.Warning />} title="Export unavailable" message={phase.message} />
        ) : (
          <>
            <OptionRow label="Resolution">
              {RESOLUTIONS.map((option) => (
                <Button key={option.value} variant={settings.resolution === option.value ? "pill-prominent" : "pill"} disabled={busy} aria-pressed={settings.resolution === option.value} onClick={() => setSettings((s) => ({ ...s, resolution: option.value }))}>{option.label}</Button>
              ))}
            </OptionRow>
            <OptionRow label="Frame rate">
              {FRAME_RATES.map((option) => (
                <Button key={String(option.value)} variant={settings.fps === option.value ? "pill-prominent" : "pill"} disabled={busy} aria-pressed={settings.fps === option.value} onClick={() => setSettings((s) => ({ ...s, fps: option.value }))}>{option.label}</Button>
              ))}
            </OptionRow>

            {phase.kind === "rendering" && (
              <div className="export-progress" aria-live="polite">
                <div className="export-progress-row">
                  <Spinner size={16} />
                  <span className="export-stage">{phase.progress.stage}</span>
                  <span className="export-percent tabular">{Math.round(phase.progress.fraction * 100)}%</span>
                </div>
                <progress className="export-bar" max={1} value={phase.progress.fraction} />
                <Button variant="pill" onClick={cancel}>Cancel</Button>
              </div>
            )}

            {phase.kind === "error" && <Notice icon={<Icon.Warning />} title="Export failed" message={phase.message} />}

            {phase.kind === "done" && (
              <div className="export-result">
                <Notice icon={<Icon.Check />} title={phase.cached ? "Already rendered" : "Rendered"} message={`${phase.artifact.width}×${phase.artifact.height} · ${phase.artifact.fps} fps · ${byteCount(phase.artifact.bytes)} · ${phase.artifact.videoCodec === "avc" ? "H.264 MP4" : "VP9 WebM"}${phase.artifact.audioCodec ? "" : " · no audio"}`} tint="var(--signal)" />
                <div className="export-actions">
                  <Button variant="pill-prominent" onClick={() => void download(phase.artifact)}><Icon.Import />Save</Button>
                  {canShareFiles() && <Button variant="pill" onClick={() => void share(phase.artifact)} disabled={shareState === "sharing"}><Icon.Share />Share</Button>}
                  <Button variant="pill" onClick={render}>Render again</Button>
                </div>
                {shareState === "failed" && <p className="export-hint">Sharing files is not available here. Save the video instead.</p>}
              </div>
            )}

            {(phase.kind === "idle" || phase.kind === "error") && (
              <div className="export-footer">
                <p className="export-hint">Export creates one shareable video without changing the originals.</p>
                <Button variant="pill-prominent" onClick={render} disabled={composition.clips.length === 0}><Icon.Film />Render video</Button>
              </div>
            )}
          </>
        )}
      </section>
    </div>
  );
}

function OptionRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="export-option" role="group" aria-label={label}>
      <span className="export-option-label">{label}</span>
      <div className="export-option-choices">{children}</div>
    </div>
  );
}

function Notice({ icon, title, message, tint = "var(--fg-secondary)" }: { icon: React.ReactNode; title: string; message: string; tint?: string }) {
  return (
    <div className="export-notice" style={{ "--tint": tint } as React.CSSProperties}>
      <span className="export-notice-icon">{icon}</span>
      <div>
        <strong>{title}</strong>
        <p>{message}</p>
      </div>
    </div>
  );
}

export default ExportSheet;
