import { randomUUID } from "node:crypto";
import { PgDialect } from "drizzle-orm/pg-core";
import type { SQL } from "drizzle-orm";
import { describe, expect, it, vi } from "vitest";
import { createMediaRoutes } from "./media.js";

const dialect = new PgDialect();

function uploadFixture(previousName: string, status = "complete") {
  const mediaId = randomUUID();
  const previousId = randomUUID();
  let replaced = false;
  const execute = vi.fn(async (statement: SQL) => {
    const { sql } = dialect.sqlToQuery(statement);
    if (sql.includes("from member")) return [{ role: "member" }];
    if (sql.includes("from media_uploads where organization_id")) return [{
      id: previousId, fileName: previousName, totalBytes: "123", contentType: "video/mp4",
      chunkSize: 8388608, totalParts: 1, status,
    }];
    if (sql.startsWith("delete from media_uploads")) replaced = true;
    if (sql.includes("from media_upload_parts")) return replaced ? [] : [{ partNumber: 1 }];
    return [];
  });
  const db = { execute, transaction: async (work: (tx: { execute: typeof execute }) => unknown) => work({ execute }) };
  const store = { createMultipart: vi.fn(async () => randomUUID()) };
  const auth = { api: { getSession: async () => ({ user: { id: "member" } }) } };
  const app = createMediaRoutes(db as never, auth as never, new Map([["local", store as never]]), "local", "http://localhost");
  const request = (fileName: string) => app.request("/uploads", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ organizationId: "project-org", mediaId, fileName, contentType: "video/mp4", totalBytes: 123 }),
  });
  return { request, previousId, store };
}

describe("render upload revisions", () => {
  it("reuses a completed upload of the same render", async () => {
    const fixture = uploadFixture("video-revision-one.mp4");
    const response = await fixture.request("video-revision-one.mp4");
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ uploadId: fixture.previousId, status: "complete" });
    expect(fixture.store.createMultipart).not.toHaveBeenCalled();
  });

  it.each(["complete", "uploading"])("starts a clean session for a changed render even if the previous upload is %s and the size matches", async (status) => {
    const fixture = uploadFixture("video-revision-one.mp4", status);
    const response = await fixture.request("video-revision-two.mp4");
    expect(response.status).toBe(200);
    const result = await response.json();
    expect(result.uploadId).not.toBe(fixture.previousId);
    expect(result.status).toBe("uploading");
    expect(result.receivedParts).toEqual([]);
    expect(fixture.store.createMultipart).toHaveBeenCalledOnce();
  });
});

it.each([true, false])("only completes the current render upload (still current: %s)", async (current) => {
  const mediaId = randomUUID();
  const uploadId = randomUUID();
  const execute = vi.fn(async (statement: SQL) => {
    const { sql } = dialect.sqlToQuery(statement);
    if (sql.includes('media_id as "mediaId"')) return [{
      mediaId, organizationId: "org", userId: "member", contentType: "video/mp4", totalBytes: "3",
      totalParts: 1, status: "uploading", storageProfile: "local", providerUploadId: "provider",
    }];
    if (sql.includes("from media_upload_parts")) return [{ partNumber: 1, size: "3", checksum: "new-checksum" }];
    if (sql.startsWith("select id from media_uploads")) return current ? [{ id: uploadId }] : [];
    return [];
  });
  const db = { execute, transaction: async (work: (tx: { execute: typeof execute }) => unknown) => work({ execute }) };
  const store = { completeMultipart: vi.fn(async () => {}) };
  const auth = { api: { getSession: async () => ({ user: { id: "member" } }) } };
  const app = createMediaRoutes(db as never, auth as never, new Map([["local", store as never]]), "local", "http://localhost");
  const response = await app.request(`/uploads/${uploadId}/complete`, { method: "POST" });
  expect(response.status).toBe(current ? 200 : 409);
  expect(store.completeMultipart).toHaveBeenCalledTimes(current ? 1 : 0);
  if (!current) expect(await response.json()).toEqual({ error: "upload_replaced" });
});
