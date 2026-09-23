import { useMemo, useState } from "react";
import { Link } from "react-router";
import type { Project } from "@/domain";
import { projects as projectRepository } from "@/storage/repository";
import { useLiveQuery } from "@/storage/live";
import { routes } from "@/app/routes";
import { Button, Card, EmptyState, MetaLabel, ScreenHeader, Spinner, StatusPill } from "@/design/components";
import { Icon } from "@/design/icons";
import { Menu } from "@/design/sheet";
import { useLayoutMetrics } from "@/design/layout";
import { ProjectForm } from "./ProjectForm";
import { VideoThumbnail } from "./VideoThumbnail";
import { filterProjects, projectSubtitle, projectSummary, sortProjects } from "./project-summary";
import { useProjectMedia } from "./use-project-media";
import "./ProjectsScreen.css";

/** Port of ProjectsView: searchable list/grid of projects with create/edit sheets. */
export default function ProjectsScreen() {
  const [ref, layout] = useLayoutMetrics<HTMLDivElement>();
  const query = useLiveQuery(() => projectRepository.all(), ["projects"]);
  const [search, setSearch] = useState("");
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<Project | null>(null);

  const all = useMemo(() => sortProjects(query.data ?? []), [query.data]);
  const filtered = useMemo(() => filterProjects(all, search), [all, search]);
  const isGrid = layout.gridColumns > 1;

  return (
    <div ref={ref} className="pj">
      <ScreenHeader title="Projects" actions={<button type="button" className="ds-menu-trigger" aria-label="New project" title="New project" onClick={() => setCreating(true)}><Icon.Plus /></button>}>
        {all.length > 0 && (
          <label className="pj-search">
            <Icon.Search />
            <input type="search" className="pj-search-input" placeholder="Search by name or opponent" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search projects" />
          </label>
        )}
      </ScreenHeader>

      {query.isLoading ? (
        <div className="pj-loading"><Spinner /></div>
      ) : all.length === 0 ? (
        <EmptyState icon={<Icon.Court />} title="No projects yet" message="A project is one match or training session. It is saved on this device immediately and syncs later." action={<Button variant="primary" className="pj-empty-action" onClick={() => setCreating(true)}>Create project</Button>} />
      ) : filtered.length === 0 ? (
        <EmptyState icon={<Icon.Search />} title={`No results for “${search.trim()}”`} message="Check the spelling or try a new search." />
      ) : (
        <div className={isGrid ? "pj-grid" : "pj-list"} style={isGrid ? { gridTemplateColumns: `repeat(${layout.gridColumns}, minmax(0, 1fr))` } : undefined}>
          {filtered.map((project) => <ProjectCell key={project.id} project={project} style={isGrid ? "card" : "row"} onEdit={() => setEditing(project)} />)}
        </div>
      )}

      <ProjectForm project={null} open={creating} onClose={() => setCreating(false)} />
      <ProjectForm project={editing} open={editing !== null} onClose={() => setEditing(null)} />
    </div>
  );
}

function ProjectCell({ project, style, onEdit }: { project: Project; style: "card" | "row"; onEdit: () => void }) {
  const media = useProjectMedia(project.id);
  const summary = projectSummary(media.recordings, media.compositions, media.events, media.hasLocalVideo);
  const total = summary.videoCount + summary.highlightCount;
  const menu = <Menu label="Project actions" className="pj-menu" items={[{ label: "Edit project", icon: <Icon.Pencil />, onSelect: onEdit }]} />;

  if (style === "row") {
    return (
      <Card className="pj-row-card">
        <Link to={routes.project(project.id)} className="pj-row" aria-label={`${project.name}, ${projectSubtitle(project)}, ${total} videos, ${summary.eventCount} events`}>
          <VideoThumbnail recording={summary.preview.recording} seconds={summary.preview.seconds} icon={<Icon.Video />} className="pj-row-thumb" />
          <div className="pj-text">
            <span className="pj-name">{project.name}</span>
            <span className="pj-subtitle">{projectSubtitle(project)}</span>
            <span className="pj-meta">
              <MetaLabel icon={<Icon.PlayRect />} text={`${total}`} />
              <MetaLabel icon={<Icon.Flag />} text={`${summary.eventCount}`} />
            </span>
          </div>
          {project.needsSync && <span className="pj-sync" title="Waiting to sync"><Icon.ArrowUpCircle /></span>}
          <Icon.ChevronRight className="pj-chevron" />
        </Link>
        {menu}
      </Card>
    );
  }

  return (
    <Card className="pj-card">
      <Link to={routes.project(project.id)} className="pj-card-link" aria-label={`${project.name}, ${projectSubtitle(project)}, ${total} videos, ${summary.eventCount} events`}>
        <VideoThumbnail recording={summary.preview.recording} seconds={summary.preview.seconds} icon={<Icon.Video />} className="pj-card-thumb">
          {project.needsSync && <span className="vt-corner"><StatusPill text="Waiting to sync" tint="var(--warning)" icon={<Icon.ArrowUpCircle />} /></span>}
        </VideoThumbnail>
        <div className="pj-card-body">
          <span className="pj-name">{project.name}</span>
          <span className="pj-subtitle">{projectSubtitle(project)}</span>
          <span className="pj-meta">
            <MetaLabel icon={<Icon.PlayRect />} text={`${total} videos`} />
            <MetaLabel icon={<Icon.Flag />} text={`${summary.eventCount} events`} />
          </span>
        </div>
      </Link>
      <div className="pj-card-menu">{menu}</div>
    </Card>
  );
}
