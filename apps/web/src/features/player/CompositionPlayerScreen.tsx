import { useMemo, useState } from "react";
import { useNavigate, useParams } from "react-router";
import { Button, EmptyState, Spinner, StatTile } from "@/design/components";
import { Icon } from "@/design/icons";
import { useLayoutMetrics } from "@/design/layout";
import { compactDuration } from "@/design/format";
import { compositionDuration } from "@/domain";
import { compositions, events as eventStore, recordings as recordingStore } from "@/storage/repository";
import { useLiveQuery } from "@/storage/live";
import { routes } from "@/app/router";
import { ExportSheet } from "@/features/export/ExportSheet";
import { PreviewControls } from "@/features/editor/PlaybackControls";
import { aspectShortTitle, aspectValue } from "@/features/editor/model/edits";
import { sequenceEvents } from "@/features/editor/model/sequence";
import { SequencePreview } from "./engine/SequencePreview";
import { useRecordingSources } from "./engine/useRecordingSources";
import { useSequencePlayer } from "./engine/useSequencePlayer";
import { EventsStrip } from "./EventsStrip";
import "@/features/editor/EditorScreen.css";
import "./player.css";

/** Plays a composition with its events, share link and export. Route: /projects/:projectID/watch/:compositionID. */
export default function CompositionPlayerScreen() {
  const { projectID = "", compositionID = "" } = useParams();
  const navigate = useNavigate();
  const composition = useLiveQuery(() => compositions.get(compositionID), ["compositions"], [compositionID]);
  const recordings = useLiveQuery(() => recordingStore.forProject(projectID), ["recordings"], [projectID]);
  const events = useLiveQuery(() => eventStore.forProject(projectID), ["events"], [projectID]);
  const [exporting, setExporting] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const clips = useMemo(() => composition.data?.clips ?? [], [composition.data]);
  const used = useMemo(() => (recordings.data ?? []).filter((r) => clips.some((c) => c.recordingID === r.id)), [recordings.data, clips]);
  const { sources, missing, isLoading } = useRecordingSources(used);
  const { player, state } = useSequencePlayer(clips, sources);
  const [bodyRef, layout] = useLayoutMetrics<HTMLDivElement>();
  const strip = useMemo(() => sequenceEvents(clips, (events.data ?? []).filter((e) => !e.pendingDeletion)).map((o) => ({ key: `${o.snapshot.id.eventID}-${o.snapshot.id.clipID}`, note: o.event.note, snapshot: o.snapshot })), [clips, events.data]);

  if (composition.isLoading || recordings.isLoading) return <div className="ed-loading" data-surface="dark"><Spinner /></div>;
  const video = composition.data;
  if (!video) return <div className="ed-loading" data-surface="dark"><EmptyState icon={<Icon.Film />} title="Video not found" action={<Button variant="pill" onClick={() => navigate(routes.project(projectID))}>Back to project</Button>} /></div>;
  const duration = compositionDuration(clips);
  const missingClips = clips.some((c) => missing.includes(c.recordingID) || !used.some((r) => r.id === c.recordingID));
  const unavailable = !isLoading && (missingClips || clips.length === 0);
  const first = sources.find((s) => s.recordingID === clips[0]?.recordingID);
  const ratio = aspectValue(video.aspectRatio) ?? (first?.width && first.height ? first.width / first.height : 16 / 9);
  const share = async () => {
    if (!video.shareURL) return;
    try {
      if (navigator.share) await navigator.share({ title: video.name, url: video.shareURL });
      else { await navigator.clipboard.writeText(video.shareURL); setNotice("Link copied"); setTimeout(() => setNotice(null), 2000); }
    } catch { /* cancelled */ }
  };
  return (
    <div className="pl-root" data-surface="dark">
      <header className="pl-header">
        <button type="button" className="ed-icon-button" aria-label="Back to project" onClick={() => { player.pause(); navigate(routes.project(projectID)); }}><Icon.ChevronLeft /></button>
        <h1>{video.name}</h1>
        <button type="button" className="ed-action" disabled={unavailable} onClick={() => { player.pause(); navigate(routes.edit(projectID, video.id)); }}><Icon.Scissors /> Edit</button>
      </header>
      <div ref={bodyRef} className="pl-body" data-landscape={layout.isLandscape || undefined}>
        <div className="pl-stage" style={{ "--stage-ratio": ratio } as React.CSSProperties}>
          <SequencePreview player={player} aspectRatio={video.aspectRatio}>
            <div className="ed-preview-gradient" />
            <PreviewControls isPlaying={state.isPlaying} isPreparing={!state.isReady && !state.error && !unavailable} isEnabled={state.isReady && !state.error} currentTime={state.outputTime} totalTime={duration} play={() => player.toggle()} previousFrame={() => player.step(-1)} nextFrame={() => player.step(1)} />
          </SequencePreview>
          {(unavailable || state.error) && <div className="ed-preview-error"><div><h3>Cannot play video</h3><p>{state.error ?? "Its original videos are unavailable on this device."}</p></div></div>}
        </div>
        <div className="pl-panel">
          <div className="pl-scrub">
            <span className="mono ed-dim">{compactDuration(state.outputTime)}</span>
            <input type="range" min={0} max={Math.max(0.1, duration)} step={0.1} value={Math.min(state.outputTime, duration)} aria-label="Playback position" onChange={(e) => player.seek(Number(e.target.value))} />
            <span className="mono ed-dim">{compactDuration(duration)}</span>
          </div>
          <EventsStrip events={strip} duration={duration} currentTime={state.outputTime} onSeek={(s) => player.seek(s)} />
          <div className="pl-stats">
            <StatTile value={`${clips.length}`} title={clips.length === 1 ? "Clip" : "Clips"} icon={<Icon.Film />} tint="var(--highlight)" />
            <StatTile value={compactDuration(duration)} title="Duration" icon={<Icon.Clock />} tint="var(--brand)" />
            <StatTile value={aspectShortTitle(video.aspectRatio)} title="Format" icon={<Icon.Stack />} tint="var(--fg-secondary)" />
          </div>
          <div className="pl-actions">
            <Button variant="primary" tint="var(--signal)" style={{ color: "#000" }} disabled={unavailable} onClick={() => { player.pause(); setExporting(true); }}><Icon.Share /> Export</Button>
            {video.shareURL && <Button variant="secondary" onClick={share}><Icon.Share /> Share web player link</Button>}
          </div>
          <p className="pl-footnote">{video.uploadState === "uploaded" ? "This video is synced. The web-player link plays the rendered file." : "Export renders one shareable video without changing the originals. Camelot uploads exported videos during sync and creates a web-player link."}</p>
        </div>
        {notice && <div className="ed-notice" role="status"><Icon.Check />{notice}</div>}
      </div>
      {exporting && <ExportSheet composition={video} onClose={() => setExporting(false)} />}
    </div>
  );
}
