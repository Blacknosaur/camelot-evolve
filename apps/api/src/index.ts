import { serve } from "@hono/node-server";
import { createDatabase } from "@camelot/db";
import { createApp } from "./app.js";
import { createAuth } from "./auth.js";
import { loadConfig } from "./config.js";

const config = loadConfig();
const { db } = createDatabase(config.DATABASE_URL);
const auth = createAuth(db, config);
const app = createApp(db, auth, {
  storageRoot: config.MEDIA_STORAGE_PATH,
  publicBaseURL: config.PUBLIC_BASE_URL,
  defaultStorageProfile: config.DEFAULT_STORAGE_PROFILE,
  storageProfilesJSON: config.STORAGE_PROFILES_JSON,
});

serve({ fetch: app.fetch, port: config.PORT }, ({ port }) => {
  console.log(`Camelot API listening on http://localhost:${port}`);
});
