import { z } from "zod";

const configSchema = z.object({
  DATABASE_URL: z.url().default("postgres://camelot:camelot_local@localhost:5432/camelot"),
  BETTER_AUTH_SECRET: z.string().min(32),
  BETTER_AUTH_URL: z.url().default("http://localhost:3000"),
  PORT: z.coerce.number().int().min(1).max(65535).default(3000),
  MEDIA_STORAGE_PATH: z.string().default("/tmp/camelot-media"),
  DEFAULT_STORAGE_PROFILE: z.string().default("local"),
  STORAGE_PROFILES_JSON: z.string().default("{}"),
  PUBLIC_BASE_URL: z.url().default("http://localhost:3000"),
});

export type Config = z.infer<typeof configSchema>;
export const loadConfig = (): Config => configSchema.parse(process.env);
