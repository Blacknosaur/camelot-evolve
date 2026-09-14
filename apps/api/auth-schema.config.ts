import { createDatabase } from "@camelot/db";
import { betterAuth } from "better-auth/minimal";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { organization } from "better-auth/plugins";

const { db } = createDatabase(process.env.DATABASE_URL ?? "postgres://camelot:camelot_local@localhost:5432/camelot");

export const auth = betterAuth({
  database: drizzleAdapter(db, { provider: "pg" }),
  emailAndPassword: { enabled: true },
  plugins: [organization({ teams: { enabled: true } })],
});
