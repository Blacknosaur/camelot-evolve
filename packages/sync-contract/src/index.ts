import { z } from "zod";

export const entityTypeSchema = z.enum([
  "project",
  "media",
  "event",
  "collection",
  "summary",
]);

export const syncMutationSchema = z.object({
  mutationId: z.uuid(),
  entityId: z.uuid(),
  entityType: entityTypeSchema,
  operation: z.enum(["upsert", "delete"]),
  baseVersion: z.number().int().nonnegative().nullable(),
  parentId: z.uuid().nullable().optional(),
  payload: z.record(z.string(), z.unknown()).default({}),
  clientTimestamp: z.iso.datetime(),
});

export const pushRequestSchema = z.object({
  organizationId: z.string().min(1),
  deviceId: z.uuid(),
  mutations: z.array(syncMutationSchema).min(1).max(100),
});

export const pullQuerySchema = z.object({
  organizationId: z.string().min(1),
  cursor: z.string().regex(/^\d+$/).default("0"),
  limit: z.coerce.number().int().min(1).max(500).default(200),
});

export type EntityType = z.infer<typeof entityTypeSchema>;
export type SyncMutation = z.infer<typeof syncMutationSchema>;
export type PushRequest = z.infer<typeof pushRequestSchema>;
