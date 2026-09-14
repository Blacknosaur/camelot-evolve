import type { Database } from "@camelot/db";
import { pullQuerySchema, pushRequestSchema } from "@camelot/sync-contract";
import { zValidator } from "@hono/zod-validator";
import { Hono } from "hono";
import { requestId } from "hono/request-id";
import { secureHeaders } from "hono/secure-headers";
import { sql } from "drizzle-orm";
import type { Auth } from "./auth.js";
import { pull, push } from "./sync.js";
import { createMediaRoutes } from "./media.js";
import { createStorageProfiles } from "./storage.js";

type Variables = { userId: string };

export function createApp(db: Database, auth: Auth, options = { storageRoot: "/tmp/camelot-media", publicBaseURL: "http://localhost:3000", defaultStorageProfile: "local", storageProfilesJSON: "{}" }) {
  const app = new Hono<{ Variables: Variables }>().basePath("/api");
  app.use("*", requestId(), secureHeaders());
  app.get("/health", (c) => c.json({ status: "ok" as const }));
  app.on(["GET", "POST"], "/auth/*", (c) => auth.handler(c.req.raw));
  const stores = createStorageProfiles(options.storageRoot, options.storageProfilesJSON);
  app.route("/", createMediaRoutes(db, auth, stores, options.defaultStorageProfile, options.publicBaseURL));

  app.use("/sync/*", async (c, next) => {
    const session = await auth.api.getSession({ headers: c.req.raw.headers });
    if (!session) return c.json({ error: "unauthorized" }, 401);
    c.set("userId", session.user.id);
    await next();
  });

  app.use("/sync/*", async (c, next) => {
    const body = c.req.method === "GET" ? undefined : await c.req.raw.clone().json();
    const organizationId = c.req.method === "GET"
      ? c.req.query("organizationId")
      : (body as { organizationId?: string }).organizationId;
    if (!organizationId) return c.json({ error: "organization_required" }, 400);
    const membership = await db.execute(sql`
      select 1 from member where organization_id = ${organizationId} and user_id = ${c.get("userId")} limit 1
    `);
    if (!membership[0]) return c.json({ error: "forbidden" }, 403);
    await next();
  });

  app.post("/sync/push", zValidator("json", pushRequestSchema), async (c) => {
    const request = c.req.valid("json");
    return c.json({ results: await push(db, request) });
  });
  app.get("/sync/pull", zValidator("query", pullQuerySchema), async (c) => {
    const query = c.req.valid("query");
    return c.json(await pull(db, query.organizationId, query.cursor, query.limit));
  });

  app.notFound((c) => c.json({ error: "not_found" }, 404));
  app.onError((error, c) => {
    console.error(error);
    return c.json({ error: "internal_error" }, 500);
  });
  return app;
}
