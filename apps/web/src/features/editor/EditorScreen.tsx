import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import { useNavigate, useParams } from "react-router";
import { clipAnnotationEnd, clipAnnotationRate, clampRate, defaultPostRoll, defaultPreRoll, eventTint, newId, now, type CompositionClip, type EventKind, type MatchEvent, type Recording, type UUID, type VideoComposition } from "@/domain";
import { Button, EmptyState, Spinner } from "@/design/components";
import { Icon } from "@/design/icons";
import { useLayoutMetrics } from "@/design/layout";
import { compactDuration } from "@/design/format";
import { compositions, events as eventStore, recordings as recordingStore } from "@/storage/repository";
import { useLiveQuery } from "@/storage/live";
import { routes } from "@/app/router";
import { SequencePreview } from "@/features/player/engine/SequencePreview";
import { useRecordingSources } from "@/features/player/engine/useRecordingSources";
import { useSequencePlayer } from "@/features/player/engine/useSequencePlayer";
import { EventBrowser, type RangeDraft } from "./EventBrowser";
import { EventEditorSheet, type EventEditorTarget } from "./EventEditorSheet";
import { EventTagStrip } from "./EventTagStrip";
import { FootagePicker, type FootageChoice } from "./FootagePicker";
import { Menu } from "./Menu";
import { PanelDivider } from "./PanelDivider";
import { PreviewControls } from "./PlaybackControls";
import { Timeline, type TimelineClip } from "./Timeline";
import { VideoSettingsSheet } from "./VideoSettingsSheet";
import { EditorIcon } from "./icons";
import { ASPECT_RATIOS, FREEZE_OPTIONS, SPEED_OPTIONS, aspectShortTitle, aspectTitle, canSplit, clipsEqual, compositionWithEdit, duplicateClip, insertClips, insertFreezeFrame, removeClip, reorderClip, setClipRate, setFreezeDuration, splitClip, trimClip, type EditorDocument } from "./model/edits";
import { makeSnapshot, panelSizes, sameEventID, snapshotEnd, snapshotStart, timelineTimecode, trimRange, videoAspectRatioLabel, type TimelineEventID, type TimelineEventSnapshot } from "./model/geometry";
import { clipsForEvents, eventClips, fullClip, makeClip } from "./model/manifests";
import { clipLabel, segmentContaining, segmentsForClips, sequenceEventOffset, sequenceEvents, sourceTimeAt, outputTimeAt, type SequenceEvent } from "./model/sequence";
import { useEditorDocument } from "./useEditorDocument";
import "./EditorScreen.css";

/* Route: /projects/:projectID/edit/:compositionID. The ID is a saved composition, or a recording
   ID for a fresh edit of one source video (saved as a composition on the first Save/close). */
export default function EditorScreen() {
  const { projectID = "", compositionID = "" } = useParams();
  const navigate = useNavigate();
  const composition = useLiveQuery(() => compositions.get(compositionID), ["compositions"], [compositionID]);
  const recording = useLiveQuery(() => recordingStore.get(compositionID), ["recordings"], [compositionID]);
  const projectRecordings = useLiveQuery(() => recordingStore.forProject(projectID), ["recordings"], [projectID]);
  const projectEvents = useLiveQuery(() => eventStore.forProject(projectID), ["events"], [projectID]);
  const [seed, setSeed] = useState<{ composition: VideoComposition | null; recording: Recording | null } | null>(null);
  useEffect(() => {
    if (seed || composition.isLoading || recording.isLoading) return;
    if (composition.data || recording.data) setSeed({ composition: composition.data ?? null, recording: recording.data ?? null });
  }, [seed, composition, recording]);
  const loading = !seed && (composition.isLoading || recording.isLoading || projectRecordings.isLoading || projectEvents.isLoading);
  if (loading) return <div className="ed-loading" data-surface="dark"><Spinner /></div>;
  if (!seed || !projectRecordings.data || !projectEvents.data) {
    return <div className="ed-loading" data-surface="dark"><EmptyState icon={<Icon.Film />} title="Video not found" message="This video is no longer in the project." action={<Button variant="pill" onClick={() => navigate(routes.project(projectID))}>Back to project</Button>} /></div>;
  }
  return <EditorWorkspace key={seed.composition?.id ?? seed.recording?.id} projectID={projectID} composition={seed.composition} sourceRecording={seed.recording} recordings={projectRecordings.data.filter((r) => !r.pendingDeletion)} events={projectEvents.data.filter((e) => !e.pendingDeletion)} />;
}

type Tool = "clips" | "trim";

interface WorkspaceProps { projectID: UUID; composition: VideoComposition | null; sourceRecording: Recording | null; recordings: Recording[]; events: MatchEvent[] }

function EditorWorkspace({ projectID, composition, sourceRecording, recordings, events: projectEvents }: WorkspaceProps) {
  const navigate = useNavigate();
  const baseRecording = sourceRecording ?? recordings.find((r) => r.id === composition?.clips[0]?.recordingID) ?? recordings[0] ?? null;
  const initialClips = composition?.clips.length ? composition.clips : baseRecording ? [fullClip(baseRecording)] : [];
  const { document: doc, commit, select, undo, redo, canUndo, canRedo } = useEditorDocument({ clips: initialClips, selectedClipID: initialClips[0]?.id ?? "", aspectRatio: composition?.aspectRatio ?? "original", deletedEventIDs: [] });
  const [saved, setSaved] = useState<VideoComposition | null>(composition);
  const [videoName, setVideoName] = useState(composition?.name ?? baseRecording?.name ?? "");
  const [tool, setTool] = useState<Tool>("clips");
  const [trimStart, setTrimStart] = useState(initialClips[0]?.startSeconds ?? 0);
  const [trimEnd, setTrimEnd] = useState(initialClips[0]?.endSeconds ?? 0);
  const [showingEventList, setShowingEventList] = useState(false);
  const [showingQuickEvents, setShowingQuickEvents] = useState(false);
  const [quickCounts, setQuickCounts] = useState<Partial<Record<EventKind, number>>>({});
  const [lastQuick, setLastQuick] = useState<EventKind | null>(null);
  const [eventSearch, setEventSearch] = useState("");
  const [eventKind, setEventKind] = useState<string | null>(null);
  const [selectedEventID, setSelectedEventID] = useState<UUID | null>(null);
  const [selectedAnnotationID, setSelectedAnnotationID] = useState<TimelineEventID | null>(null);
  const [zoom, setZoom] = useState(1);
  const [draft, setDraft] = useState<RangeDraft | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [workspaceHeight, setWorkspaceHeight] = useState(320);
  const [sidebarWidth, setSidebarWidth] = useState(390);
  const [editorTarget, setEditorTarget] = useState<EventEditorTarget | null>(null);
  const [showingSettings, setShowingSettings] = useState(false);
  const [picker, setPicker] = useState<{ atStart: boolean } | null>(null);
  const [bodyRef, layout] = useLayoutMetrics<HTMLDivElement>();
  const sequencePosition = useRef(0);
  const noticeTimer = useRef(0);
  const quickTimer = useRef(0);

  const visibleEvents = useMemo(() => projectEvents.filter((e) => !doc.deletedEventIDs.includes(e.id)), [projectEvents, doc.deletedEventIDs]);
  const recordingMap = useMemo(() => new Map(recordings.map((r) => [r.id, r] as const)), [recordings]);
  const selectedClip = doc.clips.find((c) => c.id === doc.selectedClipID) ?? doc.clips[0];
  const activeRecording = (selectedClip && recordingMap.get(selectedClip.recordingID)) ?? baseRecording;
  const segments = useMemo(() => segmentsForClips(doc.clips), [doc.clips]);
  const occurrences = useMemo(() => sequenceEvents(doc.clips, visibleEvents), [doc.clips, visibleEvents]);
  const annotationEvents = useMemo(() => annotationTimelineEvents(doc.clips, segments), [doc.clips, segments]);
  const selectedOccurrence = selectedEventID ? occurrences.find((o) => o.snapshot.id.eventID === selectedEventID && o.snapshot.id.clipID === doc.selectedClipID) ?? null : null;

  // Playback: one player for the screen; clips swap between the assembled edit and the trim source.
  const usedRecordings = useMemo(() => recordings.filter((r) => doc.clips.some((c) => c.recordingID === r.id) || r.id === activeRecording?.id), [recordings, doc.clips, activeRecording?.id]);
  const { sources, missing, isLoading: loadingSources } = useRecordingSources(usedRecordings);
  const trimClips = useMemo<CompositionClip[]>(() => (activeRecording ? [makeClip(activeRecording.id, 0, Math.max(0.1, activeRecording.duration))] : []), [activeRecording]);
  const engineClips = tool === "clips" ? doc.clips : trimClips;
  const { player, state } = useSequencePlayer(engineClips, sources);
  const missingUsed = missing.filter((id) => doc.clips.some((c) => c.recordingID === id));
  const preparing = !state.isReady && !state.error && (loadingSources || missingUsed.length === 0);
  const previewError = state.error ?? (missingUsed.length > 0 && !loadingSources ? "None of the original videos are available on this device." : null);
  const playbackEnabled = !previewError && (tool === "trim" || state.isReady);
  const currentTime = state.outputTime;
  const duration = tool === "clips" ? state.duration : activeRecording?.duration ?? 0;

  useEffect(() => {
    if (tool !== "clips" || !state.isReady) return;
    sequencePosition.current = state.outputTime;
    if (selectedEventID == null && selectedAnnotationID == null && state.activeClipID && state.activeClipID !== doc.selectedClipID) select(state.activeClipID);
  }, [tool, state.isReady, state.outputTime, state.activeClipID, selectedEventID, selectedAnnotationID, doc.selectedClipID, select]);

  const showNotice = useCallback((message: string) => {
    setNotice(message);
    clearTimeout(noticeTimer.current);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 2000);
  }, []);

  useEffect(() => () => { clearTimeout(noticeTimer.current); clearTimeout(quickTimer.current); }, []);

  // MARK: Selection & seeking

  const selectClipWithoutSeeking = useCallback((clipID: UUID) => { setSelectedEventID(null); select(clipID); }, [select]);
  const seekToClip = (clipID: UUID, clips = doc.clips) => {
    const seconds = segmentsForClips(clips).find((s) => s.id === clipID)?.start ?? 0;
    sequencePosition.current = seconds;
    player.seek(seconds);
  };
  const selectClip = (clipID: UUID, clips = doc.clips) => {
    selectClipWithoutSeeking(clipID);
    if (tool === "clips") seekToClip(clipID, clips);
    else { const clip = clips.find((c) => c.id === clipID); if (clip) player.seek(clip.startSeconds); }
  };
  const selectOccurrence = (occurrence: SequenceEvent) => {
    if (occurrence.snapshot.id.clipID) select(occurrence.snapshot.id.clipID);
    setSelectedAnnotationID(null);
    setSelectedEventID(occurrence.snapshot.id.eventID);
  };
  const fitRange = (start: number, end: number) => {
    setZoom(Math.max(1, duration / Math.max(2, (end - start) * 2)));
    player.seek((start + end) / 2);
  };
  const focusEvent = (occurrence: SequenceEvent) => { selectOccurrence(occurrence); setShowingEventList(false); fitRange(snapshotStart(occurrence.snapshot), snapshotEnd(occurrence.snapshot)); };

  const togglePlayback = () => {
    if (state.isPlaying) { player.pause(); return; }
    if (tool === "clips") {
      if (!state.isReady) return;
      if (selectedOccurrence) {
        const s = snapshotStart(selectedOccurrence.snapshot), e = snapshotEnd(selectedOccurrence.snapshot);
        player.playRange(currentTime >= s && currentTime < e - 0.05 ? currentTime : s, e);
      } else player.playRange(currentTime >= duration - 0.05 ? 0 : currentTime, null);
      return;
    }
    player.playRange(currentTime >= trimStart && currentTime < trimEnd - 0.05 ? currentTime : trimStart, trimEnd);
  };

  // MARK: Clip edits

  const selectedSourceTime = (() => {
    if (tool !== "clips") return currentTime;
    const segment = segments.find((s) => s.id === doc.selectedClipID);
    return segment ? sourceTimeAt(segment, currentTime) : trimStart;
  })();

  const doSplit = () => {
    const result = commit((d) => { const r = splitClip(d.clips, d.selectedClipID, selectedSourceTime); return r ? { ...d, clips: r.clips, selectedClipID: r.trailingID } : null; });
    if (result) { const trailing = result.clips.find((c) => c.id === result.selectedClipID); if (trailing) { setTrimStart(trailing.startSeconds); setTrimEnd(trailing.endSeconds); } showNotice("Clip split"); }
  };
  const doReorder = (id: UUID, destination: number) => {
    const result = commit((d) => { const clips = reorderClip(d.clips, id, destination); return clips ? { ...d, clips, selectedClipID: id } : null; });
    if (result) { player.pause(); setSelectedEventID(null); sequencePosition.current = segmentsForClips(result.clips).find((s) => s.id === id)?.start ?? 0; player.seek(sequencePosition.current); showNotice("Clip moved"); }
  };
  const doRemove = (clip: CompositionClip) => {
    const result = commit((d) => { const r = removeClip(d.clips, clip.id); return r ? { ...d, clips: r.clips, selectedClipID: r.selectedClipID } : null; });
    if (result) { selectClip(result.selectedClipID, result.clips); showNotice("Clip removed"); }
  };
  const doRate = (rate: number) => {
    if (commit((d) => { const clips = setClipRate(d.clips, d.selectedClipID, rate); return clips ? { ...d, clips } : null; })) showNotice(`Speed set to ${clampRate(rate)}×`);
  };
  const doFreezeDuration = (seconds: number) => {
    if (commit((d) => { const clips = setFreezeDuration(d.clips, d.selectedClipID, seconds); return clips ? { ...d, clips } : null; })) showNotice(`Hold set to ${seconds}s`);
  };
  const doFreeze = () => {
    const result = commit((d) => { const r = insertFreezeFrame(d.clips, d.selectedClipID, selectedSourceTime, 5, activeRecording?.duration ?? Number.POSITIVE_INFINITY); return r ? { ...d, clips: r.clips, selectedClipID: r.frozenID } : null; });
    if (result) { seekToClip(result.selectedClipID, result.clips); showNotice("Freeze frame added to timeline"); }
  };
  const doDuplicate = () => {
    const result = commit((d) => { const r = duplicateClip(d.clips, d.selectedClipID); return r ? { ...d, clips: r.clips, selectedClipID: r.copyID } : null; });
    if (result) { seekToClip(result.selectedClipID, result.clips); showNotice("Clip repeated"); }
  };
  const doAspect = (aspect: string) => {
    if (commit((d) => (d.aspectRatio === aspect ? null : { ...d, aspectRatio: aspect }))) showNotice(aspectTitle(aspect));
  };
  const restore = (snapshot: EditorDocument | null) => {
    if (!snapshot) return;
    setSelectedEventID(null); setSelectedAnnotationID(null);
    const clip = snapshot.clips.find((c) => c.id === snapshot.selectedClipID) ?? snapshot.clips[0];
    if (clip) { setTrimStart(clip.startSeconds); setTrimEnd(clip.endSeconds); seekToClip(clip.id, snapshot.clips); }
  };

  // MARK: Trim tool

  const beginTrim = () => {
    if (!selectedClip || selectedClip.freezeDuration != null) return;
    sequencePosition.current = currentTime;
    setTrimStart(selectedClip.startSeconds); setTrimEnd(selectedClip.endSeconds);
    setTool("trim"); setShowingEventList(false); setSelectedEventID(null); setSelectedAnnotationID(null);
    player.pause();
    const recordingDuration = activeRecording?.duration ?? 0;
    setZoom(Math.max(1, recordingDuration / Math.max(2, (selectedClip.endSeconds - selectedClip.startSeconds) * 2)));
    queueMicrotask(() => player.seek((selectedClip.startSeconds + selectedClip.endSeconds) / 2));
  };
  const returnToSequence = (sourceTime: number | null) => {
    player.pause(); setSelectedEventID(null); setShowingEventList(false); setTool("clips"); setZoom(1);
    const target = sourceTime;
    queueMicrotask(() => {
      const segment = segmentsForClips(doc.clips).find((s) => s.id === doc.selectedClipID);
      player.seek(segment && target != null ? outputTimeAt(segment, target) : sequencePosition.current);
    });
  };
  const saveTrim = () => {
    const sourceTime = currentTime;
    const result = commit((d) => { const clips = trimClip(d.clips, d.selectedClipID, trimStart, trimEnd); return clips ? { ...d, clips } : null; });
    const clips = result?.clips ?? doc.clips;
    player.pause(); setSelectedEventID(null); setShowingEventList(false); setTool("clips"); setZoom(1);
    const segment = segmentsForClips(clips).find((s) => s.id === doc.selectedClipID);
    queueMicrotask(() => player.seek(segment ? outputTimeAt(segment, sourceTime) : 0));
  };
  const cancelTrim = () => {
    if (selectedClip) { setTrimStart(selectedClip.startSeconds); setTrimEnd(selectedClip.endSeconds); }
    returnToSequence(null);
  };
  const nudgeBoundary = (leading: boolean, delta: number) => {
    const value = (leading ? trimStart : trimEnd) + delta;
    const [s, e] = trimRange(value, trimStart, trimEnd, duration, leading);
    if (s === trimStart && e === trimEnd) return;
    setTrimStart(s); setTrimEnd(e); player.seek(leading ? s : e);
  };
  const setBoundaryToPlayhead = (leading: boolean) => {
    if (leading) setTrimStart(Math.min(currentTime, trimEnd - 0.1));
    else setTrimEnd(Math.max(currentTime, trimStart + 0.1));
  };

  // MARK: Events

  const persistEvent = async (event: MatchEvent) => { await eventStore.save({ ...event, needsSync: true }); };
  const addQuickEvent = async (kind: EventKind) => {
    const playhead = player.currentTime;
    let source: Recording | undefined; let seconds = playhead;
    if (tool === "clips") {
      const segment = segmentContaining(playhead, segments);
      if (!segment) return;
      source = recordingMap.get(segment.recordingID); seconds = sourceTimeAt(segment, playhead);
    } else source = activeRecording ?? undefined;
    if (!source) return;
    const offset = Math.max(0, Math.min(source.duration, seconds));
    const event: MatchEvent = { id: newId(), projectID: source.projectID, recordingID: source.id, kind, note: "", occurredAt: new Date(new Date(source.recordedAt || source.createdAt).getTime() + offset * 1000).toISOString(), offsetSeconds: offset, preRollSeconds: Math.min(defaultPreRoll(kind), offset), postRollSeconds: Math.min(defaultPostRoll(kind), Math.max(0, source.duration - offset)), colorHex: "", contextRecordingIDs: [], pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId() };
    try { await persistEvent(event); } catch { showNotice("Could not save event"); return; }
    setQuickCounts((c) => ({ ...c, [kind]: (c[kind] ?? 0) + 1 }));
    setLastQuick(kind);
    clearTimeout(quickTimer.current);
    quickTimer.current = window.setTimeout(() => setLastQuick(null), 800);
  };
  const toggleQuickEvents = () => {
    if (selectedEventID != null) { setSelectedEventID(null); setShowingQuickEvents(true); return; }
    const next = !showingQuickEvents;
    setShowingQuickEvents(next);
    setWorkspaceHeight((h) => Math.max(230, h + (next ? 58 : -58)));
  };
  const updateEventWindow = async (event: MatchEvent, preRoll: number, postRoll: number) => {
    const source = recordingMap.get(event.recordingID ?? "");
    const beforeLimit = event.contextRecordingIDs.length === 0 ? event.offsetSeconds : Math.max(120, event.preRollSeconds);
    await persistEvent({ ...event, preRollSeconds: Math.max(0, Math.min(beforeLimit, preRoll)), postRollSeconds: Math.max(0, Math.min((source?.duration ?? activeRecording?.duration ?? 0) - event.offsetSeconds, postRoll)) });
  };
  const deleteEvent = (event: MatchEvent) => {
    player.pause();
    if (selectedEventID === event.id) setSelectedEventID(null);
    if (doc.deletedEventIDs.includes(event.id)) return;
    commit((d) => ({ ...d, deletedEventIDs: [...d.deletedEventIDs, event.id] }));
    showNotice("Event deleted · Undo to restore");
  };
  const updateAnnotationWindow = (id: TimelineEventID, preRoll: number, postRoll: number): boolean => {
    const snapshot = annotationEvents.find((e) => sameEventID(e.id, id));
    const segment = segments.find((s) => s.id === id.clipID);
    if (!snapshot || !segment) return false;
    commit((d) => {
      const clip = d.clips.find((c) => c.id === id.clipID);
      const mark = clip?.annotations.find((a) => a.id === id.eventID);
      if (!clip || !mark || mark.isLocked) return null;
      const rate = clipAnnotationRate(clip);
      const start = Math.max(clip.startSeconds, clip.startSeconds + (Math.max(snapshot.lowerBound, snapshot.offset - preRoll) - segment.start) * rate);
      const end = Math.min(clipAnnotationEnd(clip), clip.startSeconds + (Math.min(snapshot.upperBound, snapshot.offset + postRoll) - segment.start) * rate);
      return { ...d, clips: d.clips.map((c) => (c.id === clip.id ? { ...c, annotations: c.annotations.map((a) => (a.id === mark.id ? { ...a, start, end } : a)) } : c)) };
    });
    return true;
  };

  // MARK: Saving

  const draftName = () => videoName.trim() || "Video edit";
  const saveVideo = async (): Promise<VideoComposition | null> => {
    if (!doc.clips.length) return null;
    const name = draftName();
    const video: VideoComposition = saved
      ? compositionWithEdit(saved, doc.clips, doc.aspectRatio, name)
      : { id: newId(), projectID, name, kind: "custom", createdAt: now(), clips: [...doc.clips], aspectRatio: doc.aspectRatio, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId() };
    try {
      const stored = await compositions.save(video);
      const wasDraft = !saved;
      setSaved(stored);
      if (wasDraft) navigate(routes.edit(projectID, stored.id), { replace: true });
      return stored;
    } catch { showNotice("Could not save video"); return null; }
  };
  const openWatch = async (video: VideoComposition | null) => { if (video) { player.pause(); navigate(routes.watch(projectID, video.id)); } };
  const saveSelectedClip = async (clip: CompositionClip) => {
    const index = doc.clips.findIndex((c) => c.id === clip.id);
    const video: VideoComposition = { id: newId(), projectID, name: `Clip ${index + 1}`, kind: "clip", createdAt: now(), clips: [clip], aspectRatio: doc.aspectRatio, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId() };
    try { await openWatch(await compositions.save(video)); } catch { showNotice("Could not save clip"); }
  };
  const saveSelectedEvent = async (event: MatchEvent) => {
    const clips = clipsForEvents([event], recordings);
    if (!clips.length) return;
    const video: VideoComposition = { id: newId(), projectID, name: event.kind, kind: "event", createdAt: now(), clips, aspectRatio: doc.aspectRatio, uploadState: "local", uploadedBytes: 0, shareURL: null, pendingDeletion: false, serverVersion: null, needsSync: true, mutationID: newId() };
    try { await openWatch(await compositions.save(video)); } catch { showNotice("Could not save event video"); }
  };
  const closeEditor = async () => {
    if (tool === "trim") { cancelTrim(); return; }
    const original = baseRecording ? [fullClip(baseRecording)] : [];
    const unchanged = !!baseRecording && doc.clips.length === 1 && clipsEqual([{ ...doc.clips[0]!, id: "" }], [{ ...original[0]!, id: "" }]);
    const hasEdits = saved != null || !unchanged || doc.aspectRatio !== "original";
    if (hasEdits) { if (!(await saveVideo())) return; }
    else if (baseRecording && videoName.trim() && videoName.trim() !== baseRecording.name) await recordingStore.save({ ...baseRecording, name: videoName.trim() });
    try { for (const event of projectEvents) if (doc.deletedEventIDs.includes(event.id)) await eventStore.save({ ...event, pendingDeletion: true }); }
    catch { showNotice("Could not save event deletions"); return; }
    player.pause();
    navigate(routes.project(projectID));
  };
  const openAnalysis = async () => {
    const video = await saveVideo();
    if (!video) return;
    const segment = segmentContaining(currentTime, segments);
    const clipID = segment?.id ?? doc.selectedClipID;
    player.pause();
    navigate(routes.analyze(projectID, video.id, clipID));
  };

  // MARK: Footage

  const chooseFootage = (choice: FootageChoice) => {
    const atStart = picker?.atStart ?? false;
    setPicker(null);
    if (choice.kind === "event") {
      const additions = eventClips(choice.recording, choice.event, recordings);
      if (!additions.length) { showNotice("Could not add event"); return; }
      const result = commit((d) => ({ ...d, clips: insertClips(d.clips, additions, atStart), selectedClipID: additions[0]!.id }));
      if (result) { if (tool === "trim") setTool("clips"); selectClip(additions[0]!.id, result.clips); showNotice("Event added to edit"); }
      return;
    }
    const clip = fullClip(choice.recording);
    const result = commit((d) => ({ ...d, clips: insertClips(d.clips, [clip], atStart), selectedClipID: clip.id }));
    if (!result) return;
    if (tool === "trim") setTool("clips");
    selectClip(clip.id, result.clips);
    if (choice.kind === "range") queueMicrotask(() => { setTrimStart(clip.startSeconds); setTrimEnd(clip.endSeconds); setTool("trim"); setShowingEventList(false); setSelectedEventID(null); setZoom(1); });
  };

  // MARK: Keyboard

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      if (target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT" || target.isContentEditable)) return;
      if (editorTarget || showingSettings || picker) return;
      if (e.key === " ") { e.preventDefault(); togglePlayback(); }
      else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") { e.preventDefault(); if (tool !== "clips") return; restore(e.shiftKey ? redo() : undo()); }
      else if (e.key === "," ) player.step(-1);
      else if (e.key === ".") player.step(1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // MARK: Render

  const displayTitle = videoName.trim() || "Untitled video";
  const eventPaletteVisible = showingQuickEvents && !showingEventList && tool !== "trim" && !selectedOccurrence;
  const minimumWorkspace = (tool === "trim" && !showingEventList ? 278 : 206) + (eventPaletteVisible ? 58 : 0);
  const sizes = panelSizes(layout.height, workspaceHeight, minimumWorkspace);
  const sidebar = Math.min(Math.max(300, sidebarWidth), Math.max(300, layout.width - 240));
  const timelineClips: TimelineClip[] = tool === "trim" ? [] : segments.map((segment, index) => ({ segment, number: index + 1 }));
  const timelineEvents = useMemo<TimelineEventSnapshot[]>(() => (tool === "trim" ? [] : [...occurrences.map((o) => o.snapshot), ...annotationEvents]), [tool, occurrences, annotationEvents]);
  const activeSelectedEventID = selectedAnnotationID ?? selectedOccurrence?.snapshot.id ?? null;
  const previewAspectLabel = (() => { const source = sources.find((s) => s.recordingID === (state.activeRecordingID ?? doc.clips[0]?.recordingID)); return source?.width && source.height ? videoAspectRatioLabel(source.width, source.height) : "…"; })();

  const preview = (
    <div className="ed-preview" style={layout.isLandscape ? undefined : { height: sizes.preview }}>
      <SequencePreview player={player} aspectRatio={tool === "trim" ? "original" : doc.aspectRatio}>
        <div className="ed-preview-gradient" />
        <PreviewControls isPlaying={state.isPlaying} isPreparing={tool === "clips" && preparing} isEnabled={playbackEnabled} currentTime={currentTime} totalTime={duration} play={togglePlayback} previousFrame={() => player.step(-1)} nextFrame={() => player.step(1)} />
      </SequencePreview>
      {previewError && (
        <div className="ed-preview-error"><div><h3>Preview unavailable</h3><p>{previewError}</p><button type="button" className="ed-action" onClick={() => player.setSources([...sources])}>Reload preview</button></div></div>
      )}
    </div>
  );

  const sequenceActions = (
    <>
      {(preparing || previewError) && tool === "clips" && (
        <div className="ed-actions-status">{preparing && !previewError ? <><Spinner size={12} /> Preparing preview…</> : <><span style={{ color: "#ff9f0a" }}>Preview unavailable</span><button type="button" className="ed-action" onClick={() => player.setSources([...sources])}>Retry</button></>}</div>
      )}
      <div className="ed-actions" aria-label="Clip actions">
        <button type="button" className="ed-action" onClick={openAnalysis} disabled={!selectedClip}><Icon.Scope /> Analyze</button>
        <span className="ed-vdivider" />
        <button type="button" className="ed-action" aria-label="Trim selected clip" disabled={!selectedClip || selectedClip.freezeDuration != null} onClick={beginTrim}><Icon.Scissors /> Trim</button>
        <button type="button" className="ed-action" aria-label="Split selected clip" disabled={!canSplit(selectedClip, selectedSourceTime) || preparing} onClick={doSplit}><EditorIcon.Split /> Split</button>
        {selectedClip && selectedClip.freezeDuration == null && (
          <Menu ariaLabel="Clip speed" icon={<EditorIcon.Speed />} label={`${selectedClip.rate}×`} items={SPEED_OPTIONS.map((rate) => ({ title: `${rate}×`, checked: Math.abs(selectedClip.rate - rate) < 0.001, onSelect: () => doRate(rate) }))} />
        )}
        {selectedClip && selectedClip.freezeDuration != null && (
          <Menu ariaLabel="Hold duration" icon={<EditorIcon.Freeze />} label={`Hold ${selectedClip.freezeDuration}s`} items={FREEZE_OPTIONS.map((s) => ({ title: `${s} s`, checked: selectedClip.freezeDuration === s, onSelect: () => doFreezeDuration(s) }))} />
        )}
        {selectedClip && selectedClip.freezeDuration == null && <button type="button" className="ed-action" aria-label="Insert freeze frame at playhead" onClick={doFreeze}><EditorIcon.Freeze /> Freeze</button>}
        {selectedClip && <button type="button" className="ed-action" aria-label="Repeat selected clip" onClick={doDuplicate}><EditorIcon.Repeat /> Repeat</button>}
        <Menu ariaLabel="Video aspect ratio" icon={<EditorIcon.Aspect />} label={doc.aspectRatio === "original" ? previewAspectLabel : aspectShortTitle(doc.aspectRatio)} items={ASPECT_RATIOS.map((a) => ({ title: aspectTitle(a), checked: doc.aspectRatio === a, onSelect: () => doAspect(a) }))} />
        {selectedClip && <button type="button" className="ed-action" aria-label="Delete selected clip" disabled={doc.clips.length <= 1} onClick={() => doRemove(selectedClip)}><Icon.Trash /> Delete</button>}
      </div>
    </>
  );

  const selectedEventActions = selectedOccurrence && (
    <div className="ed-selected-event" style={{ "--tint": eventTint(selectedOccurrence.event.colorHex, selectedOccurrence.event.kind) } as CSSProperties}>
      <div className="ed-selected-event-text">
        <span className="ed-selected-event-title">{selectedOccurrence.event.kind} · {clipLabel(selectedOccurrence)}</span>
        <span className="ed-selected-event-range mono">{timelineTimecode(draft && sameEventID(draft.eventID, selectedOccurrence.snapshot.id) ? draft.start : snapshotStart(selectedOccurrence.snapshot))} – {timelineTimecode(draft && sameEventID(draft.eventID, selectedOccurrence.snapshot.id) ? draft.end : snapshotEnd(selectedOccurrence.snapshot))}</span>
      </div>
      <button type="button" className="ed-action" aria-label="Edit selected event" onClick={() => { player.pause(); setEditorTarget({ kind: "existing", event: selectedOccurrence.event }); }}><EditorIcon.Sliders /></button>
      <button type="button" className="ed-action" aria-label="Delete selected event" onClick={() => deleteEvent(selectedOccurrence.event)}><Icon.Trash /></button>
    </div>
  );

  const annotationActions = selectedAnnotationID && (
    <div className="ed-actions">
      <button type="button" className="ed-action" onClick={async () => { const video = await saveVideo(); if (video && selectedAnnotationID.clipID) navigate(routes.analyze(projectID, video.id, selectedAnnotationID.clipID)); }}><Icon.Pencil /> Edit layer</button>
      <button type="button" className="ed-action" onClick={() => {
        const id = selectedAnnotationID;
        const segment = segments.find((s) => s.id === id.clipID);
        if (!segment) return;
        commit((d) => {
          const clip = d.clips.find((c) => c.id === id.clipID);
          const mark = clip?.annotations.find((a) => a.id === id.eventID);
          if (!clip || !mark || mark.isLocked) return null;
          const newStart = clip.startSeconds + (currentTime - segment.start) * clipAnnotationRate(clip);
          const delta = Math.max(clip.startSeconds - mark.start, Math.min(clipAnnotationEnd(clip) - mark.end, newStart - mark.start));
          return { ...d, clips: d.clips.map((c) => (c.id === clip.id ? { ...c, annotations: c.annotations.map((a) => (a.id === mark.id ? { ...a, start: a.start + delta, end: a.end + delta, keyframes: a.keyframes.map((k) => ({ ...k, time: k.time + delta })) } : a)) } : c)) };
        });
      }}><Icon.Import /> Place here</button>
      <button type="button" className="ed-action" onClick={() => {
        const id = selectedAnnotationID;
        commit((d) => { const clip = d.clips.find((c) => c.id === id.clipID); if (!clip || clip.annotations.find((a) => a.id === id.eventID)?.isLocked) return null; return { ...d, clips: d.clips.map((c) => (c.id === clip.id ? { ...c, annotations: c.annotations.filter((a) => a.id !== id.eventID) } : c)) }; });
        setSelectedAnnotationID(null);
      }}><Icon.Trash /> Delete layer</button>
      <button type="button" className="ed-action" onClick={() => setSelectedAnnotationID(null)}>Done</button>
    </div>
  );

  const timeline = (
    <Timeline
      duration={duration}
      currentTime={currentTime}
      zoom={zoom}
      onZoom={setZoom}
      clips={timelineClips}
      recordings={recordingMap}
      sourceRecording={tool === "trim" ? activeRecording ?? undefined : undefined}
      selectedClipID={doc.selectedClipID}
      selectClip={selectClipWithoutSeeking}
      reorderClip={doReorder}
      events={timelineEvents}
      selectedEventID={tool === "trim" ? null : activeSelectedEventID}
      selectEvent={(id) => {
        if (id && annotationEvents.some((e) => sameEventID(e.id, id))) { setSelectedAnnotationID(id); setSelectedEventID(null); if (id.clipID) select(id.clipID); return; }
        setSelectedAnnotationID(null);
        if (id?.clipID && doc.clips.some((c) => c.id === id.clipID)) { select(id.clipID); setSelectedEventID(id.eventID); } else setSelectedEventID(null);
      }}
      updateEventWindow={(id, preRoll, postRoll) => {
        if (updateAnnotationWindow(id, preRoll, postRoll)) return;
        const event = visibleEvents.find((e) => e.id === id.eventID);
        const clip = doc.clips.find((c) => c.id === id.clipID);
        if (!event || !clip) return;
        const rate = clampRate(clip.rate);
        updateEventWindow(event, preRoll * rate, postRoll * rate).then(() => showNotice("Event window saved"), () => showNotice("Could not save event window"));
      }}
      showsTrim={tool === "trim"}
      trimStart={trimStart}
      trimEnd={trimEnd}
      updateTrim={(s, e) => { setTrimStart(s); setTrimEnd(e); }}
      previewSeek={(s) => player.previewSeek(s)}
      commitSeek={(s) => player.seek(s)}
      onDraft={setDraft}
      addClipAtStart={tool === "clips" ? () => { player.pause(); setPicker({ atStart: true }); } : null}
      addClipAtEnd={tool === "clips" ? () => { player.pause(); setPicker({ atStart: false }); } : null}
      interactive={tool === "trim" || (!preparing && !previewError)}
      transport={{
        undo: tool === "clips" && canUndo ? () => restore(undo()) : null,
        redo: tool === "clips" && canRedo ? () => restore(redo()) : null,
        showsHistory: tool !== "trim",
        addEvent: tool === "clips" ? toggleQuickEvents : null,
        showsEvents: eventPaletteVisible,
        fit: () => { if (tool === "trim") fitRange(trimStart, trimEnd); else if (selectedOccurrence) focusEvent(selectedOccurrence); else { setZoom(1); player.seek(duration / 2); } },
        fitLabel: tool === "trim" ? "Fit clip" : selectedOccurrence ? "Fit selected event" : "Fit entire video",
      }}
    />
  );

  const workspace = (
    <div className="ed-workspace" style={layout.isLandscape ? { width: sidebar } : { height: sizes.workspace }}>
      {tool !== "trim" && (
        <div className="ed-segmented" role="tablist" aria-label="Workspace">
          <button type="button" role="tab" aria-pressed={!showingEventList} onClick={() => setShowingEventList(false)}>Timeline</button>
          <button type="button" role="tab" aria-pressed={showingEventList} onClick={() => setShowingEventList(true)}>Events ({occurrences.length})</button>
        </div>
      )}
      {eventPaletteVisible && <EventTagStrip counts={quickCounts} lastTag={lastQuick} isEnabled={!preparing} mark={addQuickEvent} />}
      {showingEventList ? (
        <EventBrowser events={occurrences} selectedID={selectedOccurrence?.snapshot.id ?? null} draft={draft} search={eventSearch} kind={eventKind} onSearch={setEventSearch} onKind={setEventKind}
          select={(o) => { if (selectedOccurrence && sameEventID(selectedOccurrence.snapshot.id, o.snapshot.id)) setSelectedEventID(null); else { selectOccurrence(o); player.seek(sequenceEventOffset(o)); } }}
          edit={(o) => { selectOccurrence(o); player.pause(); setEditorTarget({ kind: "existing", event: o.event }); }}
          remove={(o) => deleteEvent(o.event)} />
      ) : tool === "clips" ? (
        <>
          {timeline}
          {selectedOccurrence ? selectedEventActions : selectedAnnotationID ? annotationActions : sequenceActions}
        </>
      ) : (
        <>
          <div className="ed-trim-header">
            <button type="button" className="ed-action" onClick={cancelTrim}>Cancel</button>
            <span>Trim clip</span>
            <button type="button" className="ed-action" data-prominent onClick={saveTrim}>Save</button>
          </div>
          {timeline}
          <div className="ed-boundaries">
            {([["In", trimStart, true], ["Out", trimEnd, false]] as const).map(([title, value, leading]) => (
              <div className="ed-boundary" key={title}>
                <button type="button" className="ed-boundary-value" aria-label={`Jump to clip ${leading ? "start" : "end"}`} onClick={() => player.seek(value)}>
                  <span className="ed-dim">{title}</span><span className="mono">{timelineTimecode(draft && draft.eventID == null ? (leading ? draft.start : draft.end) : value)}</span>
                </button>
                <div className="ed-boundary-row">
                  <button type="button" aria-label={`Move clip ${leading ? "start" : "end"} earlier`} onClick={() => nudgeBoundary(leading, -0.1)}>−</button>
                  <button type="button" aria-label={leading ? "Set In here" : "Set Out here"} onClick={() => setBoundaryToPlayhead(leading)}>Set</button>
                  <button type="button" aria-label={`Move clip ${leading ? "start" : "end"} later`} onClick={() => nudgeBoundary(leading, 0.1)}>+</button>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
    </div>
  );

  return (
    <div className="ed-root" data-surface="dark">
      <header className="ed-header">
        <button type="button" className="ed-icon-button" aria-label="Back to project" onClick={closeEditor}><Icon.ChevronLeft /></button>
        <h1>{displayTitle}</h1>
        <button type="button" className="ed-icon-button" aria-label="Video settings" disabled={tool === "trim"} onClick={() => { player.pause(); setShowingSettings(true); }}><Icon.Gear /></button>
        <Menu ariaLabel="Save or render video" align="end" disabled={tool === "trim"} icon={<Icon.Share />} label="Save" items={[
          { title: "Save video", icon: <Icon.Check />, onSelect: async () => { if (await saveVideo()) showNotice("Video saved"); } },
          { title: `Watch & export · ${compactDuration(duration)}`, icon: <Icon.Play />, onSelect: async () => openWatch(await saveVideo()) },
          ...(selectedClip ? [{ title: `Save selected clip · ${compactDuration(segments.find((s) => s.id === selectedClip.id) ? (selectedClip.freezeDuration ?? (selectedClip.endSeconds - selectedClip.startSeconds) / clampRate(selectedClip.rate)) : 0)}`, icon: <Icon.Scissors />, onSelect: () => saveSelectedClip(selectedClip) }] : []),
          { title: "Save selected event", icon: <Icon.Flag />, disabled: !selectedOccurrence, onSelect: () => { if (selectedOccurrence) saveSelectedEvent(selectedOccurrence.event); } },
        ]} />
      </header>
      <div ref={bodyRef} className="ed-body" data-landscape={layout.isLandscape || undefined}>
        {preview}
        {layout.isLandscape
          ? <PanelDivider title="Workspace" vertical value={sidebar} min={300} max={Math.max(300, layout.width - 240)} onChange={setSidebarWidth} />
          : <PanelDivider title="Workspace" value={sizes.workspace} min={Math.min(minimumWorkspace, layout.height * 0.45)} max={Math.max(220, layout.height - 180)} onChange={setWorkspaceHeight} />}
        {workspace}
        {notice && <div className="ed-notice" role="status">{notice.startsWith("Could not") ? <Icon.Warning /> : <Icon.Check />}{notice}</div>}
      </div>
      {editorTarget && activeRecording && (
        <EventEditorSheet recording={editorTarget.kind === "existing" ? recordingMap.get(editorTarget.event.recordingID ?? "") ?? activeRecording : activeRecording} target={editorTarget} onSave={persistEvent} onDelete={deleteEvent} onClose={() => setEditorTarget(null)} />
      )}
      {showingSettings && (
        <VideoSettingsSheet title={displayTitle} aspect={doc.aspectRatio}
          deletionMessage={saved ? "This removes this video edit and its rendered file from every synced device. Source videos are kept." : "This removes the source video, its events and any saved edits that use it from every synced device. This cannot be undone."}
          onSave={async (title, aspect) => { setVideoName(title); if (saved) setSaved(await compositions.save({ ...saved, name: title })); else if (baseRecording) await recordingStore.save({ ...baseRecording, name: title }); doAspect(aspect); }}
          onDelete={async () => {
            player.pause();
            if (saved) await compositions.save({ ...saved, pendingDeletion: true });
            else if (baseRecording) { await recordingStore.save({ ...baseRecording, pendingDeletion: true }); for (const e of projectEvents) if (e.recordingID === baseRecording.id) await eventStore.save({ ...e, pendingDeletion: true }); }
            navigate(routes.project(projectID));
          }}
          onClose={() => setShowingSettings(false)} />
      )}
      {picker && <FootagePicker recordings={recordings} events={visibleEvents} onChoose={chooseFootage} onClose={() => setPicker(null)} />}
    </div>
  );
}

/** Drawing layers appear on the same ruler as match events so their duration can be adjusted here. */
function annotationTimelineEvents(clips: readonly CompositionClip[], segments: ReturnType<typeof segmentsForClips>): TimelineEventSnapshot[] {
  return segments.flatMap((segment) => {
    const clip = clips.find((c) => c.id === segment.id);
    if (!clip) return [];
    const rate = clipAnnotationRate(clip);
    const segEnd = segment.start + (clip.freezeDuration ?? Math.max(0, clip.endSeconds - clip.startSeconds) / clampRate(clip.rate));
    return clip.annotations.flatMap((mark) => {
      const start = Math.max(clip.startSeconds, mark.start), end = Math.min(clipAnnotationEnd(clip), mark.end);
      if (!(end > start)) return [];
      const midpoint = (start + end) / 2;
      return [makeSnapshot({ id: { eventID: mark.id, clipID: clip.id }, offset: segment.start + (midpoint - clip.startSeconds) / rate, preRoll: (midpoint - start) / rate, postRoll: (end - midpoint) / rate, kind: `✎ ${mark.layerName || mark.text || mark.tool}`, colorHex: "BDEB35", lowerBound: segment.start, upperBound: segEnd, isDrawing: true, isLocked: mark.isLocked === true })];
    });
  });
}
