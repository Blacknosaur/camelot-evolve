import { openDB, type DBSchema, type IDBPDatabase } from "idb";
import type { Project, MatchEvent, Recording, VideoComposition } from "@/domain";

/* Local-first metadata store. Writes commit here first and update the UI immediately;
   the future sync engine drains `outbox` against the API (see docs/architecture.md). */

export interface OutboxEntry {
  mutationID: string;
  entity: "project" | "event" | "recording" | "composition";
  entityID: string;
  op: "upsert" | "delete";
  createdAt: string;
}

interface CamelotSchema extends DBSchema {
  projects: { key: string; value: Project; indexes: { byScheduledAt: string } };
  events: { key: string; value: MatchEvent; indexes: { byProject: string; byRecording: string } };
  recordings: { key: string; value: Recording; indexes: { byProject: string } };
  compositions: { key: string; value: VideoComposition; indexes: { byProject: string } };
  outbox: { key: string; value: OutboxEntry; indexes: { byCreatedAt: string } };
  settings: { key: string; value: unknown };
}

export type CamelotDB = IDBPDatabase<CamelotSchema>;

let instance: Promise<CamelotDB> | null = null;

export function database(): Promise<CamelotDB> {
  instance ??= openDB<CamelotSchema>("camelot", 1, {
    upgrade(db) {
      db.createObjectStore("projects", { keyPath: "id" }).createIndex("byScheduledAt", "scheduledAt");
      const events = db.createObjectStore("events", { keyPath: "id" });
      events.createIndex("byProject", "projectID");
      events.createIndex("byRecording", "recordingID");
      db.createObjectStore("recordings", { keyPath: "id" }).createIndex("byProject", "projectID");
      db.createObjectStore("compositions", { keyPath: "id" }).createIndex("byProject", "projectID");
      db.createObjectStore("outbox", { keyPath: "mutationID" }).createIndex("byCreatedAt", "createdAt");
      db.createObjectStore("settings");
    },
  });
  return instance;
}

/** Test hook: drop the cached connection so a fresh database opens. */
export function resetDatabaseForTests() { instance = null; }
