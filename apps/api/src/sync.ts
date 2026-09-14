import type { Database } from "@camelot/db";
import type { PushRequest, SyncMutation } from "@camelot/sync-contract";
import { sql } from "drizzle-orm";

export type MutationResult =
  | { mutationId: string; status: "applied" | "duplicate"; version: number }
  | { mutationId: string; status: "conflict"; serverVersion: number; serverPayload: Record<string, unknown> };

type ExistingRecord = { version: number; payload: Record<string, unknown> };
type StoredResult = { result: MutationResult };
type Executor = Pick<Database, "execute">;

async function applyMutation(tx: Executor, request: PushRequest, mutation: SyncMutation): Promise<MutationResult> {
  await tx.execute(sql`select pg_advisory_xact_lock(hashtextextended(${mutation.mutationId}, 0))`);
  const duplicate = await tx.execute(sql`
    select result from processed_mutations
    where mutation_id = ${mutation.mutationId} and organization_id = ${request.organizationId}
  `) as unknown as StoredResult[];
  if (duplicate[0]) {
    const prior = duplicate[0].result;
    return { ...prior, status: "duplicate" } as MutationResult;
  }

  const existingRows = await tx.execute(sql`
    select version::integer as version, payload from sync_records
    where organization_id = ${request.organizationId}
      and entity_type = ${mutation.entityType}
      and entity_id = ${mutation.entityId}
    for update
  `) as unknown as ExistingRecord[];
  const existing = existingRows[0];
  const expectedVersion = existing?.version ?? null;

  if (expectedVersion !== mutation.baseVersion) {
    const conflict: MutationResult = {
      mutationId: mutation.mutationId,
      status: "conflict",
      serverVersion: expectedVersion ?? 0,
      serverPayload: existing?.payload ?? {},
    };
    await storeResult(tx, request, mutation, conflict);
    return conflict;
  }

  const version = (expectedVersion ?? 0) + 1;
  await tx.execute(sql`
    insert into sync_records (
      organization_id, entity_type, entity_id, parent_id, version, payload, deleted_at, updated_at
    ) values (
      ${request.organizationId}, ${mutation.entityType}, ${mutation.entityId}, ${mutation.parentId ?? null},
      ${version}, ${JSON.stringify(mutation.payload)}::jsonb,
      ${mutation.operation === "delete" ? new Date() : null}, now()
    )
    on conflict (organization_id, entity_type, entity_id) do update set
      parent_id = excluded.parent_id,
      version = excluded.version,
      payload = excluded.payload,
      deleted_at = excluded.deleted_at,
      updated_at = now()
  `);
  await tx.execute(sql`
    insert into sync_changes (
      organization_id, entity_type, entity_id, version, operation, parent_id, payload, deleted_at
    ) values (
      ${request.organizationId}, ${mutation.entityType}, ${mutation.entityId}, ${version}, ${mutation.operation},
      ${mutation.parentId ?? null}, ${JSON.stringify(mutation.payload)}::jsonb,
      ${mutation.operation === "delete" ? new Date() : null}
    )
  `);

  if (mutation.operation === "delete" && (mutation.entityType === "media" || mutation.entityType === "summary")) {
    await tx.execute(sql`
      update media_shares
      set revoked_at = now()
      where organization_id = ${request.organizationId}
        and media_id = ${mutation.entityId}
        and revoked_at is null
    `);
  }

  const result: MutationResult = { mutationId: mutation.mutationId, status: "applied", version };
  await storeResult(tx, request, mutation, result);
  return result;
}

async function storeResult(tx: Executor, request: PushRequest, mutation: SyncMutation, result: MutationResult) {
  await tx.execute(sql`
    insert into processed_mutations (mutation_id, organization_id, device_id, result)
    values (${mutation.mutationId}, ${request.organizationId}, ${request.deviceId}, ${JSON.stringify(result)}::jsonb)
  `);
}

export async function push(db: Database, request: PushRequest) {
  return db.transaction(async (tx) => {
    const results: MutationResult[] = [];
    for (const mutation of request.mutations) results.push(await applyMutation(tx, request, mutation));
    return results;
  });
}

export async function pull(db: Database, organizationId: string, cursor: string, limit: number) {
  const rows = await db.execute(sql`
    select c.sequence::text as sequence, c.entity_type as "entityType", c.entity_id as "entityId",
           c.version::integer as version, c.operation,
           c.parent_id as "parentId", c.payload, c.deleted_at as "deletedAt", c.changed_at as "changedAt"
    from sync_changes c
    where c.organization_id = ${organizationId} and c.sequence > ${cursor}::bigint
    order by c.sequence asc
    limit ${limit + 1}
  `) as unknown as Array<{
    sequence: string; entityType: string; entityId: string; version: number; operation: string;
    parentId: string | null; payload: Record<string, unknown>; deletedAt: Date | null; changedAt: Date;
  }>;
  const hasMore = rows.length > limit;
  const changes = rows.slice(0, limit);
  return { changes, cursor: changes.at(-1)?.sequence ?? cursor, hasMore };
}
