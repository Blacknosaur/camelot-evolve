import { useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { Link, useNavigate, useParams } from "react-router";
import type { MatchEvent, Project, Recording, VideoComposition } from "@/domain";
import { eventTint } from "@/domain";
import { useLiveQuery } from "@/storage/live";
import { projects as projectRepository } from "@/storage/repository";
import { importRecording } from "@/media/import";
import { routes } from "@/app/routes";
import { useAppState } from "@/app/app-state";
import { Button, Card, EmptyState, MetaLabel, ScreenHeader, SectionTitle, Spinner, StatTile, StatusPill } from "@/design/components";
import { compactDuration, friendlyDate } from "@/design/format";
import { Icon } from "@/design/icons";
import { useLayoutMetrics } from "@/design/layout";
import { ActionSheet, AlertDialog, ConfirmDialog, Menu, PromptDialog, type MenuItem } from "@/design/sheet";
import { ProjectForm } from "@/features/projects/ProjectForm";
import { VideoThumbnail } from "@/features/projects/VideoThumbnail";
import { projectSubtitle, projectSummary } from "@/features/projects/project-summary";
import { useProjectMedia } from "@/features/projects/use-project-media";
import { EventForm, eventIcon } from "./EventForm";
import { createComposition, deleteComposition, deleteRecording, renameComposition, renameRecording, shareLink, type CompositionPreset } from "./library";
import { compositionDeletionMessage, compositionIsEditable, compositionStats, compositionStatus, compositionUses, eventCountForRecording, recordingDeletionMessage, recordingStatus, recordingSubtitle, recordingTitle, remoteMediaURL, type VideoStatus } from "./video-status";
import "./ProjectDetailScreen.css";

type DeletionTarget = { kind: "recording"; recording: Recording } | { kind: "composition"; composition: VideoComposition };

/** Port of ProjectDetailView: header stats, record/import/combine actions, videos, edits and events. */
export default function ProjectDetailScreen() {
  const { projectID = "" } = useParams();
  const navigate = useNavigate();
  const [ref, layout] = useLayoutMetrics<HTMLDivElement>();
  const projectQuery = useLiveQuery(() => projectRepository.get(projectID), ["projects"], [projectID]);
  const media = useProjectMedia(projectID);
  const sync = useAppState((s) => s.sync);

  const [editingProject, setEditingProject] = useState(false);
  const [deletionTarget, setDeletionTarget] = useState<DeletionTarget | null>(null);
  const [alert, setAlert] = useState<{ title: string; message: string } | null>(null);
  const [toast, setToast] = useState<string | null>(null);
  const [renaming, setRenaming] = useState<{ title: string; value: string; save: (name: string) => Promise<void> } | null>(null);
  const [editingEvent, setEditingEvent] = useState<MatchEvent | null>(null);
  const [newEditOpen, setNewEditOpen] = useState(false);
  const [importProgress, setImportProgress] = useState<number | null>(null);
  const fileInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (!toast) return;
    const timer = setTimeout(() => setToast(null), 2200);
    return () => clearTimeout(timer);
  }, [toast]);

  const project = projectQuery.data;
  const summary = useMemo(() => projectSummary(media.recordings, media.compositions, media.events, media.hasLocalVideo), [media]);
  const isWide = layout.isLandscape && layout.width >= 640;

  if (projectQuery.isLoading) return <div className="pd-loading"><Spinner /></div>;
  if (!project) return <EmptyState icon={<Icon.Warning />} title="Project not found" action={<Link to={routes.projects} className="ds-button ds-button-secondary pd-inline-button">Back to projects</Link>} />;

  const importVideo = async (file: File) => {
    setImportProgress(0);
    try {
      await importRecording(project.id, file, (fraction) => setImportProgress(fraction));
      void sync();
    } catch (error) {
      setAlert({ title: "Could not import video", message: error instanceof Error ? error.message : "The selected video could not be read." });
    } finally { setImportProgress(null); }
  };

  const combine = () => {
    const first = media.recordings[0];
    if (first) void startEdit("custom");
  };

  const startEdit = async (preset: CompositionPreset) => {
    const created = await createComposition(project, preset, media.recordings, media.events);
    if (!created) { setAlert({ title: "Nothing to add", message: preset === "goals" ? "Tag at least one goal in a video to build a goals summary." : "Record or import a video first." }); return; }
    navigate(routes.edit(project.id, created.id));
  };

  const share = async (title: string, url: string | null) => {
    if (!url) { setAlert({ title: "Not shared yet", message: "This video gets a share link once it has uploaded to your organization." }); return; }
    const result = await shareLink(title, url);
    setToast(result === "copied" ? "Link copied" : result === "failed" ? "Could not share the link" : null);
  };

  const confirmDeletion = async () => {
    const target = deletionTarget;
    setDeletionTarget(null);
    if (!target) return;
    try {
      if (target.kind === "recording") await deleteRecording(target.recording);
      else await deleteComposition(target.composition);
      void sync();
    } catch (error) {
      setAlert({ title: "Could not delete video", message: error instanceof Error ? error.message : "The video remains available." });
    }
  };

  const openRecording = (recording: Recording) => navigate(routes.recording(project.id, recording.id));
  const openComposition = (composition: VideoComposition) => {
    const editable = compositionIsEditable(composition.clips, media.recordings, media.hasLocalVideo);
    navigate(editable ? routes.edit(project.id, composition.id) : routes.watch(project.id, composition.id));
  };

  const headerMenu: (MenuItem | "divider")[] = [
    { label: "Record video", icon: <Icon.Video />, onSelect: () => navigate(routes.camera(project.id)) },
    { label: "Import video", icon: <Icon.Import />, onSelect: () => fileInput.current?.click(), disabled: importProgress !== null },
    { label: "Combine videos", icon: <Icon.Combine />, onSelect: combine, disabled: media.recordings.length === 0 },
    "divider",
    { label: "Edit project", icon: <Icon.Pencil />, onSelect: () => setEditingProject(true) },
  ];

  const hasVideos = media.recordings.length > 0 || media.compositions.length > 0;
  const gridStyle = layout.gridColumns > 1 ? { gridTemplateColumns: `repeat(${layout.gridColumns}, minmax(0, 1fr))` } : undefined;

  return (
    <div ref={ref} className="pd" style={{ maxWidth: layout.gridColumns > 1 ? undefined : "calc(var(--readable-width) + 200px)" }}>
      <ScreenHeader
        title={project.name}
        back={<Link to={routes.projects} className="pd-back" aria-label="Back to projects"><Icon.ChevronLeft /><span>Projects</span></Link>}
        actions={<Menu items={headerMenu} label="More" />}
      />
      <input ref={fileInput} type="file" accept="video/*,.mov,.mp4,.m4v,.webm" className="sr-only" tabIndex={-1} onChange={(e) => { const file = e.target.files?.[0]; e.target.value = ""; if (file) void importVideo(file); }} />

      <div className="pd-body">
        <section className="pd-header">
          <div className="pd-subtitle-row">
            <span className="pd-subtitle">{project.opponent ? <Icon.Court /> : <Icon.Calendar />}{projectSubtitle(project)}</span>
            {project.needsSync && <StatusPill text="Waiting to sync" tint="var(--warning)" icon={<Icon.ArrowUpCircle />} />}
          </div>
          <div className={`pd-header-grid ${isWide ? "pd-header-grid-wide" : ""}`}>
            <div className="pd-stats">
              <StatTile value={`${summary.videoCount + summary.highlightCount}`} title="Videos" icon={<Icon.PlayRect />} tint="var(--brand)" />
              <StatTile value={`${summary.eventCount}`} title="Events" icon={<Icon.Flag />} tint="var(--success)" />
            </div>
            <div className="pd-actions">
              <Button variant="primary" onClick={() => navigate(routes.camera(project.id))}><Icon.Video />Record</Button>
              <Button variant="secondary" onClick={() => fileInput.current?.click()} disabled={importProgress !== null} aria-label="Import video">{importProgress === null ? <Icon.Import /> : <Spinner size={16} />}Import</Button>
              <Button variant="secondary" tint="var(--highlight)" onClick={combine} disabled={media.recordings.length === 0}><Icon.Combine />Combine</Button>
            </div>
          </div>
          {importProgress !== null && (
            <div className="pd-progress" role="progressbar" aria-valuenow={Math.round(importProgress * 100)} aria-valuemin={0} aria-valuemax={100} aria-label="Importing video">
              <div className="pd-progress-bar" style={{ width: `${Math.max(2, importProgress * 100)}%` }} />
              <span>Importing video… {Math.round(importProgress * 100)}%</span>
            </div>
          )}
        </section>

        {!hasVideos && !media.isLoading && (
          <Card>
            <EmptyState icon={<Icon.PlayRect />} title="No videos yet" message="Record a match or import a video from your library. Tag moments, arrange clips and render your video whenever you’re ready." />
          </Card>
        )}

        {media.recordings.length > 0 && (
          <section className="pd-section">
            <SectionTitle title="Videos" accessory={<span className="pd-count tabular">{media.recordings.length}</span>} />
            <VideoList grid={gridStyle}>
              {media.recordings.map((recording) => {
                const available = media.hasLocalVideo(recording);
                const unavailable = !available && !remoteMediaURL(recording);
                const title = recordingTitle(recording, (iso) => friendlyDate(new Date(iso)));
                const items: (MenuItem | "divider")[] = [
                  { label: "Open", icon: <Icon.Play />, onSelect: () => openRecording(recording) },
                  { label: "Rename", icon: <Icon.Pencil />, onSelect: () => setRenaming({ title: "Rename video", value: recording.name, save: (name) => renameRecording(recording, name) }) },
                  { label: "Share link", icon: <Icon.Share />, onSelect: () => void share(title, recording.shareURL), disabled: !recording.shareURL },
                  "divider",
                  { label: "Delete", icon: <Icon.Trash />, destructive: true, onSelect: () => setDeletionTarget({ kind: "recording", recording }) },
                ];
                return (
                  <VideoCell
                    key={recording.id}
                    style={gridStyle ? "card" : "row"}
                    title={title}
                    subtitle={recordingSubtitle(recording, (iso) => friendlyDate(new Date(iso)))}
                    duration={recording.duration}
                    eventCount={eventCountForRecording(media.events, recording.id)}
                    thumbnail={<VideoThumbnail recording={available ? recording : null} seconds={Math.min(1, recording.duration / 2)} className={gridStyle ? "pd-card-thumb" : "pd-row-thumb"}>{gridStyle && <span className="vt-duration">{compactDuration(recording.duration)}</span>}</VideoThumbnail>}
                    status={recordingStatus(recording, { hasLocalVideo: available, localBytes: media.localBytes[recording.id] })}
                    menu={items}
                    unavailable={unavailable}
                    onOpen={() => openRecording(recording)}
                    onDelete={() => setDeletionTarget({ kind: "recording", recording })}
                  />
                );
              })}
            </VideoList>
          </section>
        )}

        {(media.compositions.length > 0 || media.recordings.length > 0) && (
          <section className="pd-section">
            <SectionTitle title="Edits" accessory={
              <span className="pd-section-accessory">
                <span className="pd-count tabular">{media.compositions.length}</span>
                <button type="button" className="ds-menu-trigger pd-add" aria-label="New edit" title="New edit" onClick={() => setNewEditOpen(true)} disabled={media.recordings.length === 0}><Icon.Plus /></button>
              </span>
            } />
            {media.compositions.length === 0 ? (
              <Card><EmptyState icon={<Icon.Film />} title="No edits yet" message="Build a full match, a goals summary or start a custom edit from your videos." action={<Button variant="secondary" className="pd-inline-button" onClick={() => setNewEditOpen(true)}>New edit</Button>} /></Card>
            ) : (
              <VideoList grid={gridStyle}>
                {media.compositions.map((composition) => {
                  const stats = compositionStats(composition, media.events, media.recordings, media.hasLocalVideo);
                  const editable = compositionIsEditable(composition.clips, media.recordings, media.hasLocalVideo);
                  const unavailable = !editable && !remoteMediaURL(composition);
                  const items: (MenuItem | "divider")[] = [
                    { label: "Edit", icon: <Icon.Scissors />, onSelect: () => navigate(routes.edit(project.id, composition.id)), disabled: !editable },
                    { label: "Watch", icon: <Icon.Play />, onSelect: () => navigate(routes.watch(project.id, composition.id)) },
                    { label: "Rename", icon: <Icon.Pencil />, onSelect: () => setRenaming({ title: "Rename edit", value: composition.name, save: (name) => renameComposition(composition, name) }) },
                    { label: "Share link", icon: <Icon.Share />, onSelect: () => void share(composition.name, composition.shareURL), disabled: !composition.shareURL },
                    "divider",
                    { label: "Delete", icon: <Icon.Trash />, destructive: true, onSelect: () => setDeletionTarget({ kind: "composition", composition }) },
                  ];
                  return (
                    <VideoCell
                      key={composition.id}
                      style={gridStyle ? "card" : "row"}
                      title={composition.name}
                      subtitle={friendlyDate(new Date(composition.createdAt))}
                      duration={stats.duration}
                      eventCount={stats.eventCount}
                      thumbnail={<VideoThumbnail recording={stats.thumbnail.recording} seconds={stats.thumbnail.seconds} className={gridStyle ? "pd-card-thumb" : "pd-row-thumb"}>{gridStyle && <span className="vt-duration">{compactDuration(stats.duration)}</span>}</VideoThumbnail>}
                      status={compositionStatus(composition, stats.clipCount, null)}
                      menu={items}
                      unavailable={unavailable}
                      onOpen={() => openComposition(composition)}
                      onDelete={() => setDeletionTarget({ kind: "composition", composition })}
                    />
                  );
                })}
              </VideoList>
            )}
          </section>
        )}

        {media.events.length > 0 && (
          <section className="pd-section">
            <SectionTitle title="Events" accessory={<span className="pd-count tabular">{media.events.length}</span>} />
            <Card className="pd-events">
              {media.events.map((event) => {
                const recording = media.recordings.find((r) => r.id === event.recordingID);
                const tint = eventTint(event.colorHex, event.kind);
                return (
                  <button key={event.id} type="button" className="pd-event" style={{ "--tint": tint } as CSSProperties} onClick={() => setEditingEvent(event)}>
                    <span className="pd-event-icon">{eventIcon(event.kind)}</span>
                    <span className="pd-event-text">
                      <span className="pd-event-title">{event.kind}{event.note && <span className="pd-event-note"> · {event.note}</span>}</span>
                      <span className="pd-event-subtitle">{recording ? recordingTitle(recording, (iso) => friendlyDate(new Date(iso))) : "No video"}</span>
                    </span>
                    <span className="pd-event-time tabular">{compactDuration(event.offsetSeconds)}</span>
                    <Icon.ChevronRight className="pd-chevron" />
                  </button>
                );
              })}
            </Card>
          </section>
        )}
      </div>

      {toast && <div className="pd-toast" role="status">{toast}</div>}

      <ProjectForm project={project} open={editingProject} onClose={() => setEditingProject(false)} onDeleted={() => navigate(routes.projects, { replace: true })} />
      <EventForm event={editingEvent} recording={media.recordings.find((r) => r.id === editingEvent?.recordingID)} open={editingEvent !== null} onClose={() => setEditingEvent(null)} />
      <PromptDialog open={renaming !== null} onClose={() => setRenaming(null)} title={renaming?.title ?? ""} placeholder="Name" initialValue={renaming?.value ?? ""} onConfirm={(name) => void renaming?.save(name)} />
      <ActionSheet open={newEditOpen} onClose={() => setNewEditOpen(false)} title="New edit" message="Edits are manifests of clips; nothing is rendered until you export." items={[
        { label: "Full match", icon: <Icon.Film />, onSelect: () => void startEdit("full") },
        { label: "Goals summary", icon: <Icon.Ball />, onSelect: () => void startEdit("goals"), disabled: !media.events.some((e) => e.kind === "Goal" && e.recordingID) },
        { label: "Custom edit", icon: <Icon.Scissors />, onSelect: () => void startEdit("custom") },
      ]} />
      <ConfirmDialog
        open={deletionTarget !== null}
        onClose={() => setDeletionTarget(null)}
        title="Delete this video?"
        message={deletionTarget?.kind === "recording" ? recordingDeletionMessage(media.compositions.filter((c) => compositionUses(c, deletionTarget.recording.id)).length) : compositionDeletionMessage}
        confirmLabel="Delete permanently"
        onConfirm={() => void confirmDeletion()}
      />
      <AlertDialog open={alert !== null} onClose={() => setAlert(null)} title={alert?.title ?? ""} message={alert?.message} />
    </div>
  );
}

function VideoList({ grid, children }: { grid: CSSProperties | undefined; children: ReactNode }) {
  return grid ? <div className="pd-grid" style={grid}>{children}</div> : <Card className="pd-rows">{children}</Card>;
}

interface VideoCellProps {
  style: "row" | "card";
  title: string;
  subtitle: string;
  duration: number;
  eventCount: number;
  thumbnail: ReactNode;
  status: VideoStatus;
  menu: (MenuItem | "divider")[];
  unavailable: boolean;
  onOpen: () => void;
  onDelete: () => void;
}

/** Port of VideoLibraryCell: a row on phones, a card in grids. */
function VideoCell({ style, title, subtitle, duration, eventCount, thumbnail, status, menu, unavailable, onOpen, onDelete }: VideoCellProps) {
  const StatusIcon = Icon[status.icon];
  const pill = <StatusPill text={status.text} tint={status.tint} icon={<StatusIcon />} />;
  const label = `${title}, ${compactDuration(duration)}, ${eventCount} events, ${status.text}`;
  const trailing = unavailable
    ? <button type="button" className="pd-trash" aria-label="Delete unavailable video" onClick={onDelete}><Icon.Trash /></button>
    : <Menu items={menu} label="Video actions" className="pd-cell-menu" />;

  if (style === "row") {
    return (
      <div className="pd-row-wrap">
        <button type="button" className="pd-row" onClick={onOpen} aria-label={label}>
          {thumbnail}
          <span className="pd-row-text">
            <span className="pd-title">{title}</span>
            <span className="pd-caption">{subtitle}</span>
            <span className="pd-meta">
              <MetaLabel icon={<Icon.Clock />} text={compactDuration(duration)} />
              <MetaLabel icon={<Icon.Flag />} text={`${eventCount}`} />
              {pill}
            </span>
          </span>
          <Icon.ChevronRight className="pd-chevron" />
        </button>
        {trailing}
      </div>
    );
  }
  return (
    <Card className="pd-card">
      <button type="button" className="pd-card-button" onClick={onOpen} aria-label={label}>
        {thumbnail}
        <span className="pd-card-body">
          <span className="pd-title">{title}</span>
          <span className="pd-caption">{subtitle}</span>
          <span className="pd-meta pd-meta-spread">
            <MetaLabel icon={<Icon.Flag />} text={`${eventCount} events`} />
            {pill}
          </span>
        </span>
      </button>
      <div className="pd-card-trailing">{trailing}</div>
    </Card>
  );
}
