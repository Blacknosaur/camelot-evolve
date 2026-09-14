# Architecture

## Product boundaries

Camelot has three distinct data paths:

1. **Metadata sync** — projects, video metadata, events, collections, and summaries.
2. **Media transfer** — large, resumable, content-addressed video and thumbnail uploads.
3. **Media processing** — asynchronous proxy generation, transcription, detection, and summary rendering.

Keeping these paths separate prevents a failed multi-gigabyte upload from blocking a goal tag or project rename.

## Backend

The API is a stateless Hono/Node service. Any instance can serve any request. PostgreSQL holds durable state, Better Auth sessions, organization membership, the mutation deduplication ledger, and the ordered change feed. Media routes depend on a small `ObjectStore` interface, with local-disk and S3-compatible implementations. Docker uses MinIO; production prefers Cloudflare R2 but can register any compatible endpoint.

Storage credentials are named deployment profiles and never stored in organization data. An organization stores only its selected profile key, and only owners/admins may change it. Each upload pins its profile so an organization can change future storage without stranding an upload already in progress. The next scale optimization is returning presigned multipart URLs so video bytes travel directly between devices and object storage rather than through Hono.

Background processing will be a separate worker deployment. The API creates durable jobs transactionally; workers claim them with PostgreSQL `FOR UPDATE SKIP LOCKED` initially. Add a dedicated queue only after measured throughput requires it.

## Offline-first client model

Every client has:

- a local database (SQLite on iOS/Android, SQLite WASM/OPFS on web);
- a materialized local record table;
- an ordered outbox with stable mutation UUIDs;
- a per-organization server cursor;
- a separate transfer queue for media bytes.

Writes commit locally first and update the UI immediately. Sync then repeats:

1. Push up to 100 queued mutations.
2. Mark applied mutation IDs complete; surface conflicts explicitly.
3. Pull change pages until `hasMore` is false.
4. Apply each page and its cursor in one local transaction.
5. Subscribe for a lightweight “changes available” hint, then pull again.

Polling and real-time notifications both use the same pull endpoint. Notifications may be lost without losing data.

This is WAL-inspired without copying Git. The outbox is the client write-ahead log, `processed_mutations` is the idempotency ledger, and `sync_changes` is the ordered server log. A Git-style DAG, branches, and object graph would add conflict and garbage-collection complexity without helping normal app synchronization. We retain stable IDs, hashes, cursors, checkpoints, and compaction—the useful ideas—while keeping one linear feed per organization.

## Recording transfer and playback

Recordings upload independently from metadata in fixed 8 MiB parts. Initiation is idempotent by organization and media ID and returns the already-received part numbers, so relaunching the app resumes instead of restarting. Every part has a SHA-256 checksum; completion verifies the part count and total byte size before publishing an immutable asset.

The source upload is not an HLS playlist. Splitting a camera recording into playable HLS while capturing complicates codec boundaries and recovery. We upload opaque resumable parts, expose the completed original through HTTP range requests immediately, and will asynchronously generate CMAF/HLS renditions for adaptive playback on slower connections. Public player URLs use revocable random share tokens.

Native capture writes fragmented QuickTime files with a one-second fragment interval into an app-owned recovery directory. Before capture starts it atomically writes a journal containing the recording and project IDs, wall-clock start, timezone, mode, and media path. On launch, promoted rolling clips and normal recordings left by a crash are recovered into the library; unselected rolling-buffer files are deleted. A user stop, camera/audio interruption, or transition to the background closes the active file as a durable segment. Resuming creates a new segment; the project can join segments later without rewriting them.

Throw-away capture uses bounded 5- or 10-second recording segments and keeps at most the previous and active segment. Tapping an event promotes that context and extends the active segment for post-roll, then buffering continues automatically. Events point to the active recording ID and may reference the preceding context segment, preserving accurate pre/post-roll highlight composition without retaining an entire match.

Edits are manifests: an ordered list of immutable recording IDs and time ranges. “Full match” orders every segment; “goals summary” creates ranges around goal events. Rendering and HLS generation consume the same manifest asynchronously. Cropping and manual joining extend the manifest instead of creating another source format.

## Consistency and conflicts

Each record has a server version. A mutation includes the version the client edited (`baseVersion`). The server atomically applies it only when versions match. Retries are idempotent by `mutationId`.

Initial conflict policy is deliberately explicit:

- independent new records merge naturally;
- stale updates return the current server payload;
- deletes are tombstones and sync like other changes;
- the client offers “keep mine”, “keep theirs”, or a domain-specific merge and submits a new mutation.

Automatic field-level last-write-wins is not the default because it silently loses coaching work. We can later add commutative operations for high-frequency event counters or ordered annotations where evidence supports it.

## Tenancy and authorization

An individual account owns a personal organization, so all content follows one authorization model. Shared clubs and teams are organizations with Better Auth memberships and invitations. Teams group members inside an organization; content sharing between organizations will use explicit grants rather than duplicating records or weakening tenant filters.

Every domain query must include an organization predicate after membership authorization. Production will add PostgreSQL row-level security as defense in depth once connection/session scoping is implemented and tested.

## Domain model

The first sync store supports `project`, `media`, `event`, `collection`, and `summary`. Stable identity, parent relationships, versions, deletion state, and tenant ownership are normalized columns; evolving domain attributes live in validated payloads. As query patterns stabilize, frequently queried attributes move to typed columns or dedicated read models without changing the sync envelope.

Media records refer to immutable source objects and derived proxies. Edits are non-destructive instruction graphs. Native renderers use AVFoundation/Metal on Apple and Media3/MediaCodec/OpenGL or Vulkan on Android. Web uses WebCodecs first, with WASM fallbacks; WebGPU is for effects, not baseline playback.

## Scale path

- Horizontally scale API containers immediately.
- Use PgBouncer or a managed pooler before increasing API replica counts.
- Partition `sync_changes` by time or organization only after table metrics justify it.
- Compact old changes after all active-device cursors and retention windows allow it; require a snapshot reset for expired cursors.
- Generate low-resolution proxies early; upload sources in resumable chunks and hash each part.
- Keep detection optional and capability-driven on-device; run authoritative server detection asynchronously.
