import { schema, type Database } from "@camelot/db";
import { betterAuth } from "better-auth/minimal";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { organization } from "better-auth/plugins";
import type { Config } from "./config.js";

export function createAuth(db: Database, config: Config) {
  return betterAuth({
    baseURL: config.BETTER_AUTH_URL,
    secret: config.BETTER_AUTH_SECRET,
    database: drizzleAdapter(db, { provider: "pg", schema }),
    emailAndPassword: { enabled: true },
    advanced: { database: { joins: true } },
    plugins: [organization({ teams: { enabled: true } })],
  });
}

export type Auth = ReturnType<typeof createAuth>;
