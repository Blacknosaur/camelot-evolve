import { bigint, index, integer, jsonb, pgTable, primaryKey, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";

export const syncRecords = pgTable("sync_records", {
  organizationId: text("organization_id").notNull(),
  entityType: text("entity_type").notNull(),
  entityId: uuid("entity_id").notNull(),
  parentId: uuid("parent_id"),
  version: bigint("version", { mode: "number" }).notNull(),
  payload: jsonb("payload").$type<Record<string, unknown>>().notNull().default({}),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
}, (table) => [
  primaryKey({ columns: [table.organizationId, table.entityType, table.entityId] }),
  index("sync_records_org_parent_idx").on(table.organizationId, table.parentId),
]);

export const syncChanges = pgTable("sync_changes", {
  sequence: bigint("sequence", { mode: "number" }).primaryKey().generatedAlwaysAsIdentity(),
  organizationId: text("organization_id").notNull(),
  entityType: text("entity_type").notNull(),
  entityId: uuid("entity_id").notNull(),
  version: bigint("version", { mode: "number" }).notNull(),
  operation: text("operation").notNull(),
  parentId: uuid("parent_id"),
  payload: jsonb("payload").$type<Record<string, unknown>>().notNull().default({}),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
  changedAt: timestamp("changed_at", { withTimezone: true }).notNull().defaultNow(),
}, (table) => [index("sync_changes_org_sequence_idx").on(table.organizationId, table.sequence)]);

export const processedMutations = pgTable("processed_mutations", {
  mutationId: uuid("mutation_id").primaryKey(),
  organizationId: text("organization_id").notNull(),
  deviceId: uuid("device_id").notNull(),
  result: jsonb("result").$type<Record<string, unknown>>().notNull(),
  processedAt: timestamp("processed_at", { withTimezone: true }).notNull().defaultNow(),
}, (table) => [uniqueIndex("processed_mutations_org_mutation_idx").on(table.organizationId, table.mutationId)]);

export const mediaUploads = pgTable("media_uploads", {
  id: uuid("id").primaryKey(),
  organizationId: text("organization_id").notNull(),
  mediaId: uuid("media_id").notNull(),
  userId: text("user_id").notNull(),
  fileName: text("file_name").notNull(),
  contentType: text("content_type").notNull(),
  totalBytes: bigint("total_bytes", { mode: "number" }).notNull(),
  chunkSize: integer("chunk_size").notNull(),
  totalParts: integer("total_parts").notNull(),
  status: text("status").notNull().default("uploading"),
  storageProfile: text("storage_profile").notNull().default("local"),
  providerUploadId: text("provider_upload_id"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
}, (table) => [
  uniqueIndex("media_uploads_org_media_idx").on(table.organizationId, table.mediaId),
  index("media_uploads_user_idx").on(table.userId),
]);

export const mediaUploadParts = pgTable("media_upload_parts", {
  uploadId: uuid("upload_id").notNull(),
  partNumber: integer("part_number").notNull(),
  size: bigint("size", { mode: "number" }).notNull(),
  checksum: text("checksum").notNull(),
  providerEtag: text("provider_etag"),
  receivedAt: timestamp("received_at", { withTimezone: true }).notNull().defaultNow(),
}, (table) => [primaryKey({ columns: [table.uploadId, table.partNumber] })]);

export const mediaAssets = pgTable("media_assets", {
  id: uuid("id").primaryKey(),
  organizationId: text("organization_id").notNull(),
  storageKey: text("storage_key").notNull().unique(),
  contentType: text("content_type").notNull(),
  totalBytes: bigint("total_bytes", { mode: "number" }).notNull(),
  checksum: text("checksum").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const organizationStorage = pgTable("organization_storage", {
  organizationId: text("organization_id").primaryKey(),
  profileKey: text("profile_key").notNull(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).notNull().defaultNow(),
});

export const mediaShares = pgTable("media_shares", {
  token: text("token").primaryKey(),
  organizationId: text("organization_id").notNull(),
  mediaId: uuid("media_id").notNull(),
  createdBy: text("created_by").notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  expiresAt: timestamp("expires_at", { withTimezone: true }),
  revokedAt: timestamp("revoked_at", { withTimezone: true }),
}, (table) => [index("media_shares_media_idx").on(table.organizationId, table.mediaId)]);
