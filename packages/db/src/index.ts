import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as authSchema from "./auth-schema.js";
import * as syncSchema from "./schema.js";

export const schema = { ...authSchema, ...syncSchema };

export function createDatabase(url: string) {
  const client = postgres(url, { max: 10, prepare: false });
  return { db: drizzle(client, { schema }), client };
}

export type Database = ReturnType<typeof createDatabase>["db"];
export * from "./schema.js";
export * from "./auth-schema.js";
