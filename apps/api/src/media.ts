import type { Database } from "@camelot/db";
import { zValidator } from "@hono/zod-validator";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import path from "node:path";
import { sql } from "drizzle-orm";
import { Hono } from "hono";
import { z } from "zod";
import type { Auth } from "./auth.js";
import type { ObjectStore } from "./storage.js";

const CHUNK_SIZE = 8 * 1024 * 1024;
const initiateSchema = z.object({
  organizationId: z.string().min(1), mediaId: z.uuid(), fileName: z.string().min(1).max(255),
  contentType: z.string().startsWith("video/").max(100), totalBytes: z.number().int().positive().max(100 * 1024 ** 3),
});
const shareSchema = z.object({ organizationId: z.string().min(1), mediaId: z.uuid() });
const storageSchema = z.object({ organizationId: z.string().min(1), profileKey: z.string().min(1).max(100) });
type Session = NonNullable<Awaited<ReturnType<Auth["api"]["getSession"]>>>;

async function sessionFor(auth: Auth, headers: Headers): Promise<Session | null> { return auth.api.getSession({ headers }); }
async function isMember(db: Database, organizationId: string, userId: string) {
  const rows = await db.execute(sql`select 1 from member where organization_id = ${organizationId} and user_id = ${userId} limit 1`);
  return Boolean(rows[0]);
}
async function canManageStorage(db: Database, organizationId: string, userId: string) {
  const rows = await db.execute(sql`select role from member where organization_id = ${organizationId} and user_id = ${userId} and role in ('owner', 'admin') limit 1`);
  return Boolean(rows[0]);
}

export function createMediaRoutes(db: Database, auth: Auth, stores: Map<string, ObjectStore>, defaultProfile: string, publicBaseURL: string) {
  const routes = new Hono();
  async function profileForOrganization(organizationId: string) {
    const rows = await db.execute(sql`select profile_key as "profileKey" from organization_storage where organization_id = ${organizationId}`) as unknown as Array<{ profileKey: string }>;
    const key = rows[0]?.profileKey ?? defaultProfile;
    const store = stores.get(key);
    if (!store) throw new Error(`storage_profile_unavailable:${key}`);
    return { key, store };
  }

  routes.get("/storage", async (c) => {
    const session = await sessionFor(auth, c.req.raw.headers);
    if (!session) return c.json({ error: "unauthorized" }, 401);
    const organizationId = c.req.query("organizationId");
    if (!organizationId || !await isMember(db, organizationId, session.user.id)) return c.json({ error: "forbidden" }, 403);
    const profile = await profileForOrganization(organizationId);
    return c.json({ profileKey: profile.key, availableProfiles: [...stores.keys()] });
  });

  routes.put("/storage", zValidator("json", storageSchema), async (c) => {
    const session = await sessionFor(auth, c.req.raw.headers);
    if (!session) return c.json({ error: "unauthorized" }, 401);
    const body = c.req.valid("json");
    if (!await canManageStorage(db, body.organizationId, session.user.id)) return c.json({ error: "forbidden" }, 403);
    if (!stores.has(body.profileKey)) return c.json({ error: "storage_profile_unavailable" }, 400);
    await db.execute(sql`insert into organization_storage (organization_id, profile_key) values (${body.organizationId}, ${body.profileKey}) on conflict (organization_id) do update set profile_key = excluded.profile_key, updated_at = now()`);
    return c.json({ profileKey: body.profileKey });
  });

  routes.post("/uploads", zValidator("json", initiateSchema), async (c) => {
    const session = await sessionFor(auth, c.req.raw.headers);
    if (!session) return c.json({ error: "unauthorized" }, 401);
    const body = c.req.valid("json");
    if (!await isMember(db, body.organizationId, session.user.id)) return c.json({ error: "forbidden" }, 403);
    const upload = await db.transaction(async (tx) => {
      // Serialize replacement and completion of the same video's rendered file.
      await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${body.organizationId}), hashtext(${body.mediaId}))`);
      const rows = await tx.execute(sql`select id, file_name as "fileName", total_bytes::text as "totalBytes", content_type as "contentType", storage_profile as "storageProfile", chunk_size as "chunkSize", total_parts as "totalParts", status from media_uploads where organization_id = ${body.organizationId} and media_id = ${body.mediaId}`) as unknown as Array<{ id: string; fileName: string; totalBytes: string; contentType: string; storageProfile: string; chunkSize: number; totalParts: number; status: string }>;
      const previous = rows[0];
      if (previous && previous.fileName === body.fileName && BigInt(previous.totalBytes) === BigInt(body.totalBytes) && previous.contentType === body.contentType) {
        return previous;
      }
      const uploadId = randomUUID();
      const profile = previous && stores.has(previous.storageProfile)
        ? { key: previous.storageProfile, store: stores.get(previous.storageProfile)! }
        : await profileForOrganization(body.organizationId);
      const key = path.posix.join("assets", body.organizationId, `${body.mediaId}.video`);
      const providerUploadId = await profile.store.createMultipart(key, body.contentType);
      if (previous) {
        await tx.execute(sql`delete from media_upload_parts where upload_id = ${previous.id}`);
        await tx.execute(sql`delete from media_uploads where id = ${previous.id}`);
      }
      const totalParts = Math.ceil(body.totalBytes / CHUNK_SIZE);
      await tx.execute(sql`insert into media_uploads (id, organization_id, media_id, user_id, file_name, content_type, total_bytes, chunk_size, total_parts, storage_profile, provider_upload_id, expires_at) values (${uploadId}, ${body.organizationId}, ${body.mediaId}, ${session.user.id}, ${body.fileName}, ${body.contentType}, ${body.totalBytes}, ${CHUNK_SIZE}, ${totalParts}, ${profile.key}, ${providerUploadId}, now() + interval '7 days')`);
      return { id: uploadId, chunkSize: CHUNK_SIZE, totalParts, status: "uploading" };
    });
    const received = await db.execute(sql`select part_number as "partNumber" from media_upload_parts where upload_id = ${upload.id} order by part_number`) as unknown as Array<{ partNumber: number }>;
    return c.json({ uploadId: upload.id, chunkSize: upload.chunkSize, totalParts: upload.totalParts, receivedParts: received.map((part) => part.partNumber), status: upload.status });
  });

  routes.put("/uploads/:uploadId/parts/:partNumber", async (c) => {
    const session = await sessionFor(auth, c.req.raw.headers);
    if (!session) return c.json({ error: "unauthorized" }, 401);
    const uploadId = z.uuid().parse(c.req.param("uploadId"));
    const partNumber = z.coerce.number().int().positive().parse(c.req.param("partNumber"));
    const rows = await db.execute(sql`select user_id as "userId", organization_id as "organizationId", media_id as "mediaId", chunk_size as "chunkSize", total_parts as "totalParts", status, storage_profile as "storageProfile", provider_upload_id as "providerUploadId" from media_uploads where id = ${uploadId} and expires_at > now()`) as unknown as Array<{ userId: string; organizationId: string; mediaId: string; chunkSize: number; totalParts: number; status: string; storageProfile: string; providerUploadId: string }>;
    const upload = rows[0];
    if (!upload || upload.userId !== session.user.id) return c.json({ error: "upload_not_found" }, 404);
    if (upload.status !== "uploading" || partNumber > upload.totalParts) return c.json({ error: "invalid_part" }, 409);
    const bytes = new Uint8Array(await c.req.arrayBuffer());
    if (!bytes.byteLength || bytes.byteLength > upload.chunkSize) return c.json({ error: "invalid_part_size" }, 400);
    const checksum = createHash("sha256").update(bytes).digest("hex");
    if (c.req.header("x-chunk-sha256")?.toLowerCase() !== checksum) return c.json({ error: "checksum_mismatch" }, 400);
    const store = stores.get(upload.storageProfile);
    if (!store) return c.json({ error: "storage_profile_unavailable" }, 503);
    const key = path.posix.join("assets", upload.organizationId, `${upload.mediaId}.video`);
    const etag = await store.putPart(key, upload.providerUploadId, partNumber, bytes);
    await db.execute(sql`insert into media_upload_parts (upload_id, part_number, size, checksum, provider_etag) values (${uploadId}, ${partNumber}, ${bytes.byteLength}, ${checksum}, ${etag ?? null}) on conflict (upload_id, part_number) do update set size = excluded.size, checksum = excluded.checksum, provider_etag = excluded.provider_etag, received_at = now()`);
    return c.json({ partNumber, checksum });
  });

  routes.post("/uploads/:uploadId/complete", async (c) => {
    const session = await sessionFor(auth, c.req.raw.headers);
    if (!session) return c.json({ error: "unauthorized" }, 401);
    const uploadId = z.uuid().parse(c.req.param("uploadId"));
    const rows = await db.execute(sql`select media_id as "mediaId", organization_id as "organizationId", user_id as "userId", content_type as "contentType", total_bytes::bigint as "totalBytes", total_parts as "totalParts", status, storage_profile as "storageProfile", provider_upload_id as "providerUploadId" from media_uploads where id = ${uploadId}`) as unknown as Array<{ mediaId: string; organizationId: string; userId: string; contentType: string; totalBytes: string; totalParts: number; status: string; storageProfile: string; providerUploadId: string }>;
    const upload = rows[0];
    if (!upload || upload.userId !== session.user.id) return c.json({ error: "upload_not_found" }, 404);
    if (upload.status === "complete") return c.json({ mediaId: upload.mediaId, status: "complete" });
    const parts = await db.execute(sql`select part_number as "partNumber", size::bigint as size, checksum, provider_etag as etag from media_upload_parts where upload_id = ${uploadId} order by part_number`) as unknown as Array<{ partNumber: number; size: string; checksum: string; etag?: string }>;
    if (parts.length !== upload.totalParts) return c.json({ error: "parts_missing", received: parts.length, expected: upload.totalParts }, 409);
    if (parts.reduce((sum, part) => sum + BigInt(part.size), 0n) !== BigInt(upload.totalBytes)) return c.json({ error: "size_mismatch" }, 409);
    const store = stores.get(upload.storageProfile);
    if (!store) return c.json({ error: "storage_profile_unavailable" }, 503);
    const storageKey = path.posix.join("assets", upload.organizationId, `${upload.mediaId}.video`);
    const checksum = createHash("sha256").update(parts.map((part) => part.checksum).join(":"), "utf8").digest("hex");
    const completed = await db.transaction(async (tx) => {
      await tx.execute(sql`select pg_advisory_xact_lock(hashtext(${upload.organizationId}), hashtext(${upload.mediaId}))`);
      const live = await tx.execute(sql`select id from media_uploads where id = ${uploadId}`);
      if (!live[0]) return false;
      await store.completeMultipart(storageKey, upload.providerUploadId, parts, upload.contentType);
      await tx.execute(sql`insert into media_assets (id, organization_id, storage_key, content_type, total_bytes, checksum) values (${upload.mediaId}, ${upload.organizationId}, ${storageKey}, ${upload.contentType}, ${upload.totalBytes}, ${checksum}) on conflict (id) do update set content_type = excluded.content_type, total_bytes = excluded.total_bytes, checksum = excluded.checksum where media_assets.organization_id = excluded.organization_id`);
      await tx.execute(sql`update media_uploads set status = 'complete' where id = ${uploadId}`);
      return true;
    });
    if (!completed) return c.json({ error: "upload_replaced" }, 409);
    return c.json({ mediaId: upload.mediaId, status: "complete", checksum });
  });

  routes.post("/shares", zValidator("json", shareSchema), async (c) => {
    const session = await sessionFor(auth, c.req.raw.headers);
    if (!session) return c.json({ error: "unauthorized" }, 401);
    const body = c.req.valid("json");
    if (!await isMember(db, body.organizationId, session.user.id)) return c.json({ error: "forbidden" }, 403);
    const assets = await db.execute(sql`select 1 from media_assets where id = ${body.mediaId} and organization_id = ${body.organizationId}`);
    if (!assets[0]) return c.json({ error: "media_not_ready" }, 409);
    const token = randomBytes(24).toString("base64url");
    await db.execute(sql`insert into media_shares (token, organization_id, media_id, created_by) values (${token}, ${body.organizationId}, ${body.mediaId}, ${session.user.id})`);
    return c.json({ token, url: `${publicBaseURL}/api/watch/${token}` });
  });

  routes.get("/watch/:token", async (c) => {
    if (!(await validShare(db, c.req.param("token")))[0]) return c.html("Share not found", 404);
    return c.html(`<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Camelot video</title><style>html,body{margin:0;background:#080b10;color:white;font-family:system-ui;height:100%}main{display:grid;place-items:center;height:100%;padding:16px;box-sizing:border-box}video{width:min(100%,1200px);max-height:90vh;background:black;border-radius:12px}</style></head><body><main><video controls playsinline preload="metadata" src="/api/public/media/${c.req.param("token")}"></video></main></body></html>`);
  });

  routes.get("/public/media/:token", async (c) => {
    const share = (await validShare(db, c.req.param("token")))[0];
    if (!share) return c.json({ error: "not_found" }, 404);
    const store = stores.get(share.storageProfile);
    if (!store) return c.json({ error: "storage_profile_unavailable" }, 503);
    try {
      const object = await store.read(share.storageKey, c.req.header("range"));
      if (object.range) c.header("Content-Range", object.range);
      c.header("Accept-Ranges", "bytes");
      c.header("Content-Length", String(object.size));
      c.header("Content-Type", share.contentType);
      c.header("Content-Disposition", "inline");
      c.header("Cache-Control", "private, no-cache");
      c.header("X-Content-Type-Options", "nosniff");
      return c.body(object.body, c.req.header("range") ? 206 : 200);
    } catch (error) {
      if (error instanceof Error && error.message === "invalid_range") return c.body(null, 416);
      throw error;
    }
  });
  return routes;
}

async function validShare(db: Database, token: string) {
  return db.execute(sql`select a.storage_key as "storageKey", a.content_type as "contentType", u.storage_profile as "storageProfile" from media_shares s join media_assets a on a.id = s.media_id and a.organization_id = s.organization_id join media_uploads u on u.media_id = a.id and u.organization_id = a.organization_id where s.token = ${token} and s.revoked_at is null and (s.expires_at is null or s.expires_at > now())`) as unknown as Promise<Array<{ storageKey: string; contentType: string; storageProfile: string }>>;
}
