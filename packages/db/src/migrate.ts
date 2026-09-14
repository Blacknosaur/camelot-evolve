import "dotenv/config";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import { createDatabase } from "./index.js";

const url = process.env.DATABASE_URL ?? "postgres://camelot:camelot_local@localhost:5432/camelot";
const { db, client } = createDatabase(url);
await migrate(db, { migrationsFolder: "./drizzle" });
await client.end();

