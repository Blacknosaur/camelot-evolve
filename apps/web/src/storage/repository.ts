import type { Project, MatchEvent, Recording, VideoComposition, UUID } from "@/domain";
import { newId, now } from "@/domain";
import { database, type OutboxEntry } from "./database";
import { publishChange } from "./live";

/* OWNER: storage agent. Thin typed repository over IndexedDB. Every write marks the record
   `needsSync` with a fresh mutationID and appends an outbox entry, mirroring the iOS models. */

type Entity = OutboxEntry["entity"];
type StoreName = "projects" | "events" | "recordings" | "compositions";
const storeFor: Record<Entity, StoreName> = { project: "projects", event: "events", recording: "recordings", composition: "compositions" };

async function write<T extends { id: UUID; needsSync: boolean; mutationID: UUID }>(entity: Entity, record: T): Promise<T> {
  const db = await database();
  const stamped = { ...record, needsSync: true, mutationID: newId() };
  const tx = db.transaction([storeFor[entity], "outbox"], "readwrite");
  await tx.objectStore(storeFor[entity]).put(stamped as never);
  await tx.objectStore("outbox").put({ mutationID: stamped.mutationID, entity, entityID: record.id, op: "upsert", createdAt: now() });
  await tx.done;
  publishChange(storeFor[entity]);
  return stamped;
}

async function remove(entity: Entity, id: UUID): Promise<void> {
  const db = await database();
  const tx = db.transaction([storeFor[entity], "outbox"], "readwrite");
  await tx.objectStore(storeFor[entity]).delete(id);
  await tx.objectStore("outbox").put({ mutationID: newId(), entity, entityID: id, op: "delete", createdAt: now() });
  await tx.done;
  publishChange(storeFor[entity]);
}

export const projects = {
  all: async () => (await database()).getAllFromIndex("projects", "byScheduledAt"),
  get: async (id: UUID) => (await database()).get("projects", id),
  save: (project: Project) => write("project", project),
  delete: (id: UUID) => remove("project", id),
};

export const events = {
  forProject: async (projectID: UUID) => (await database()).getAllFromIndex("events", "byProject", projectID),
  forRecording: async (recordingID: UUID) => (await database()).getAllFromIndex("events", "byRecording", recordingID),
  get: async (id: UUID) => (await database()).get("events", id),
  save: (event: MatchEvent) => write("event", event),
  delete: (id: UUID) => remove("event", id),
};

export const recordings = {
  forProject: async (projectID: UUID) => (await database()).getAllFromIndex("recordings", "byProject", projectID),
  all: async () => (await database()).getAll("recordings"),
  get: async (id: UUID) => (await database()).get("recordings", id),
  save: (recording: Recording) => write("recording", recording),
  delete: (id: UUID) => remove("recording", id),
};

export const compositions = {
  forProject: async (projectID: UUID) => (await database()).getAllFromIndex("compositions", "byProject", projectID),
  get: async (id: UUID) => (await database()).get("compositions", id),
  save: (composition: VideoComposition) => write("composition", composition),
  delete: (id: UUID) => remove("composition", id),
};

export const settings = {
  get: async <T>(key: string) => (await database()).get("settings", key) as Promise<T | undefined>,
  set: async (key: string, value: unknown) => { await (await database()).put("settings", value, key); },
};

export const outbox = {
  pending: async () => (await database()).getAllFromIndex("outbox", "byCreatedAt"),
  complete: async (mutationIDs: UUID[]) => {
    const db = await database();
    const tx = db.transaction("outbox", "readwrite");
    await Promise.all(mutationIDs.map((id) => tx.store.delete(id)));
    await tx.done;
  },
};
