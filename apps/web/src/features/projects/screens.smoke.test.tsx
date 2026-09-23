import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, Route, Routes } from "react-router";
import type { MatchEvent, Project, Recording, VideoComposition } from "@/domain";
import { newId, now } from "@/domain";
import { publishChange } from "@/storage/live";

/* Smoke renders: every library screen mounts, reads the (mocked) repository and opens its sheets
   without throwing. IndexedDB is not available in jsdom, so the repository is an in-memory map. */

const tables = { projects: new Map<string, Project>(), events: new Map<string, MatchEvent>(), recordings: new Map<string, Recording>(), compositions: new Map<string, VideoComposition>() };
type Row = { id: string; projectID?: string; recordingID?: string };
const table = (name: keyof typeof tables) => {
  const rows = tables[name] as Map<string, Row>;
  return {
    all: async () => [...rows.values()],
    get: async (id: string) => rows.get(id),
    forProject: async (projectID: string) => [...rows.values()].filter((r) => r.projectID === projectID),
    forRecording: async (recordingID: string) => [...rows.values()].filter((r) => r.recordingID === recordingID),
    save: async (record: Row) => { rows.set(record.id, record); publishChange(name); return record; },
    delete: async (id: string) => { rows.delete(id); publishChange(name); },
  };
};

vi.mock("@/storage/repository", () => ({
  projects: table("projects"),
  events: table("events"),
  recordings: table("recordings"),
  compositions: table("compositions"),
  settings: { get: async () => undefined, set: async () => {} },
}));
vi.mock("@/storage/media-store", () => ({
  mediaStore: async () => ({ read: async () => null, list: async () => [], delete: async () => {}, size: async () => 12_345, exists: async () => false, url: async () => null, write: async () => {}, createWritable: async () => new WritableStream() }),
}));
vi.mock("@/media/thumbnails", () => ({ useThumbnail: () => null }));
vi.stubGlobal("fetch", vi.fn(() => Promise.reject(new Error("offline"))));
(HTMLDialogElement.prototype as { showModal?: () => void }).showModal ??= function (this: HTMLDialogElement) { this.setAttribute("open", ""); };
(HTMLDialogElement.prototype as { close?: () => void }).close ??= function (this: HTMLDialogElement) { this.removeAttribute("open"); };

const { useAppState } = await import("@/app/app-state");
const { default: ProjectsScreen } = await import("./ProjectsScreen");
const { default: ProjectDetailScreen } = await import("@/features/project-detail/ProjectDetailScreen");
const { default: OnboardingScreen } = await import("@/features/onboarding/OnboardingScreen");
const { default: AccountScreen } = await import("@/features/account/AccountScreen");

/* Declarative router: the data router builds a fetch Request per navigation, which jsdom's AbortSignal rejects. */
const mount = (path: string, element: React.ReactElement, route = path) =>
  render(<MemoryRouter initialEntries={[path]}><Routes><Route path={route} element={element} /><Route path="*" element={<div>elsewhere</div>} /></Routes></MemoryRouter>);

describe("library screens", () => {
  it("projects: empty state, create sheet, then the new project appears", async () => {
    const view = mount("/", <ProjectsScreen />);
    await screen.findByText("No projects yet");
    fireEvent.click(screen.getByRole("button", { name: "Create project" }));
    fireEvent.change(await screen.findByLabelText("Project name"), { target: { value: "Weekend Match" } });
    fireEvent.change(screen.getByLabelText("Opponent"), { target: { value: "Rovers" } });
    fireEvent.click(screen.getByRole("button", { name: "Create" }));
    await screen.findByText("Weekend Match");
    expect(screen.getByText(/vs Rovers/)).toBeTruthy();
    expect(tables.projects.size).toBe(1);
    view.unmount();
  });

  it("project detail: header, empty videos, menu and edit sheet", async () => {
    const id = newId();
    tables.projects.set(id, { id, name: "Cup final", opponent: "", scheduledAt: now(), createdAt: now(), serverVersion: null, needsSync: true, mutationID: newId() });
    const view = mount(`/projects/${id}`, <ProjectDetailScreen />, "/projects/:projectID");
    await screen.findByRole("heading", { name: "Cup final" });
    await screen.findByText("No videos yet");
    expect(screen.getByText("Waiting to sync")).toBeTruthy();
    fireEvent.click(screen.getByRole("button", { name: "More" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Edit project" }));
    await screen.findByRole("heading", { name: "Edit project" });
    expect((screen.getByLabelText("Project name") as HTMLInputElement).value).toBe("Cup final");
    view.unmount();
  });

  it("onboarding: validation gates submit, continue offline authenticates", async () => {
    useAppState.getState().signOut();
    const view = mount("/welcome", <OnboardingScreen />);
    const submit = await screen.findByTestId("onboarding-submit");
    expect((submit as HTMLButtonElement).disabled).toBe(true);
    fireEvent.click(screen.getByRole("radio", { name: "Sign in" }));
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "coach@example.com" } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "12345678" } });
    expect((submit as HTMLButtonElement).disabled).toBe(false);
    await waitFor(() => expect(screen.getByText("Offline")).toBeTruthy());
    fireEvent.click(screen.getByRole("button", { name: "Continue offline" }));
    expect(useAppState.getState().isAuthenticated).toBe(true);
    expect(useAppState.getState().isOfflineWorkspace).toBe(true);
    view.unmount();
  });

  it("account: profile, storage, appearance and sign-out confirmation", async () => {
    useAppState.getState().continueOffline("Ana Silva");
    const view = mount("/account", <AccountScreen />);
    expect(await screen.findByText("Ana Silva")).toBeTruthy();
    expect(screen.getByText("Offline workspace")).toBeTruthy();
    expect(screen.getByText("AS")).toBeTruthy();
    await screen.findAllByText("12 KB");
    fireEvent.click(screen.getByRole("radio", { name: "Dark" }));
    expect(document.documentElement.dataset.theme).toBe("dark");
    fireEvent.click(screen.getByRole("button", { name: "Sign out" }));
    await screen.findByText("Sign out of Camelot?");
    fireEvent.click(screen.getByRole("menuitem", { name: "Sign out" }));
    expect(useAppState.getState().isAuthenticated).toBe(false);
    view.unmount();
  });
});
