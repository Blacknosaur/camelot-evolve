import { useMemo } from "react";
import { useNavigate, useParams } from "react-router";
import { Button, EmptyState, Spinner } from "@/design/components";
import { Icon } from "@/design/icons";
import { useLayoutMetrics } from "@/design/layout";
import { compactDuration } from "@/design/format";
import { events as eventStore, recordings as recordingStore } from "@/storage/repository";
import { useLiveQuery } from "@/storage/live";
import { routes } from "@/app/router";
import { PreviewControls } from "@/features/editor/PlaybackControls";
import { fullClip } from "@/features/editor/model/manifests";
import { snapshotForEvent } from "@/features/editor/model/sequence";
import { SequencePreview } from "./engine/SequencePreview";
import { useRecordingSources } from "./engine/useRecordingSources";
import { useSequencePlayer } from "./engine/useSequencePlayer";
import { EventsStrip } from "./EventsStrip";
import "@/features/editor/EditorScreen.css";
import "./player.css";

/** Simple player for one recording with its events strip. Route: /projects/:projectID/recordings/:recordingID. */
export default function RecordingPlayerScreen() {
  const { projectID = "", recordingID = "" } = useParams();
  const navigate = useNavigate();
  const recording = useLiveQuery(() => recordingStore.get(recordingID), ["recordings"], [recordingID]);
  const events = useLiveQuery(() => eventStore.forRecording(recordingID), ["events"], [recordingID]);
  const list = useMemo(() => (recording.data ? [recording.data] : []), [recording.data]);
  const clips = useMemo(() => (recording.data ? [fullClip(recording.data)] : []), [recording.data]);
  const { sources, missing, isLoading } = useRecordingSources(list);
  const { player, state } = useSequencePlayer(clips, sources);
  const [bodyRef, layout] = useLayoutMetrics<HTMLDivElement>();
  const strip = useMemo(() => (events.data ?? []).filter((e) => !e.pendingDeletion).sort((a, b) => a.offsetSeconds - b.offsetSeconds).map((e) => ({ key: e.id, note: e.note, snapshot: snapshotForEvent(e) })), [events.data]);

  if (recording.isLoading) return <div className="ed-loading" data-surface="dark"><Spinner /></div>;
  if (!recording.data) return <div className="ed-loading" data-surface="dark"><EmptyState icon={<Icon.Film />} title="Video not found" action={<Button variant="pill" onClick={() => navigate(routes.project(projectID))}>Back to project</Button>} /></div>;
  const r = recording.data;
  const unavailable = !isLoading && missing.includes(r.id);
  const ratio = r.width && r.height ? r.width / r.height : 16 / 9;
  return (
    <div className="pl-root" data-surface="dark">
      <header className="pl-header">
        <button type="button" className="ed-icon-button" aria-label="Back to project" onClick={() => { player.pause(); navigate(routes.project(projectID)); }}><Icon.ChevronLeft /></button>
        <h1>{r.name || "Recording"}</h1>
        <button type="button" className="ed-action" onClick={() => { player.pause(); navigate(routes.edit(projectID, r.id)); }}><Icon.Scissors /> Edit</button>
      </header>
      <div ref={bodyRef} className="pl-body" data-landscape={layout.isLandscape || undefined}>
        <div className="pl-stage" style={{ "--stage-ratio": ratio } as React.CSSProperties}>
          <SequencePreview player={player} aspectRatio="original">
            <div className="ed-preview-gradient" />
            <PreviewControls isPlaying={state.isPlaying} isPreparing={!state.isReady && !state.error && !unavailable} isEnabled={state.isReady && !state.error} currentTime={state.outputTime} totalTime={state.duration || r.duration} play={() => player.toggle()} previousFrame={() => player.step(-1)} nextFrame={() => player.step(1)} />
          </SequencePreview>
          {(unavailable || state.error) && <div className="ed-preview-error"><div><h3>Cannot play video</h3><p>{state.error ?? "Its original file is not on this device."}</p></div></div>}
        </div>
        <div className="pl-panel">
          <div className="pl-scrub">
            <span className="mono ed-dim">{compactDuration(state.outputTime)}</span>
            <input type="range" min={0} max={Math.max(0.1, r.duration)} step={0.1} value={Math.min(state.outputTime, r.duration)} aria-label="Playback position" onChange={(e) => player.seek(Number(e.target.value))} />
            <span className="mono ed-dim">{compactDuration(r.duration)}</span>
          </div>
          <EventsStrip events={strip} duration={r.duration} currentTime={state.outputTime} onSeek={(s) => player.seek(s)} />
          <p className="pl-footnote">{strip.length} {strip.length === 1 ? "event" : "events"} · {compactDuration(r.duration)}</p>
        </div>
      </div>
    </div>
  );
}
