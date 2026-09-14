# Delivery plan

## Phase 0 — foundation (current)

- [x] pnpm/Turborepo workspace
- [x] local PostgreSQL and MinIO through Docker Compose/Colima
- [x] Hono health API and production container
- [x] Better Auth with email/password, organizations, invitations, and teams
- [x] versioned, idempotent push/pull sync foundation
- [x] generated schema and migration workflow
- [ ] authenticated database integration tests for signup → organization → push → pull → retry → conflict
- [ ] CI for checks, tests, migration drift, and container build

Exit criterion: two simulated devices converge after retries, reordering, duplicate delivery, conflicts, and temporary network loss.

## Phase 1 — sync reference clients

- Build a deterministic sync state machine and fixture suite in Rust.
- Add SQLite adapters for Swift and Kotlin; add SQLite WASM/OPFS for web.
- Define cursor expiry, snapshot bootstrap, tombstone retention, clock independence, and schema migration behavior.
- Add SSE “changes available” hints with reconnect/backoff; retain periodic pull.
- Run randomized convergence and crash-recovery tests.

Exit criterion: the same black-box suite passes against iOS, Android, web, and Rust implementations.

## Phase 2 — media ingestion

- [x] Define media/upload states independently from metadata sync.
- [x] Implement authenticated multipart initiation, resume, checksum validation, and completion against the development storage adapter.
- [x] Create local-first iOS recording and automatic upload flow with shareable range-based playback.
- Replace development disk storage with direct MinIO/S3 multipart URLs and add cancellation.
- Generate low-resolution CMAF/HLS proxies asynchronously.
- Add background upload policies for metered networks, battery, and old devices.

Exit criterion: interrupted multi-gigabyte recordings resume without corruption or duplicate assets.

## Phase 3 — match tagging and organization

- Projects/matches, collections, teams, rosters, event templates, and timeline events.
- Fast one-tap tagging with configurable pre/post-roll.
- Cross-organization share grants with audit logs and revocation.
- Role permissions for owner, admin, coach, analyst, and viewer.

Exit criterion: multiple coaches can tag the same match offline and resolve genuine conflicts safely.

## Phase 4 — native non-destructive editing

- Store edit decisions, never rewritten source video.
- AVFoundation/Metal renderer for iOS/macOS.
- Media3/MediaCodec GPU renderer for Android.
- WebCodecs/WebAssembly/WebGPU renderer for web with capability fallbacks.
- Golden-frame, A/V sync, thermal, memory, and export benchmarks per device tier.

Exit criterion: preview starts quickly and common highlight edits export near media-engine limits on supported hardware.

## Phase 5 — summaries and detection

- Rule-based summaries from human tags first.
- Async transcription and highlight ranking.
- Capability-gated on-device event suggestions; server-side authoritative models.
- Human confirmation and confidence display; never silently publish detections.

Exit criterion: a useful match summary requires near-zero editing while remaining correctable and traceable.

## Phase 6 — production scale and migration

- Managed PostgreSQL, object storage, backups, point-in-time recovery, and restore drills.
- Observability for sync lag, conflict rate, upload completion, job latency, and renderer performance.
- Load tests shaped like weekend match bursts, not uniform traffic.
- Explicit legacy import pipeline with checksums and reconciliation reports.

Exit criterion: tested capacity and recovery targets exceed forecast weekend peaks with headroom.

## Decisions to validate early

- Minimum OS/browser versions based on codec and local-storage capability, not marketing reach.
- Expected source resolution, bitrate, match duration, and concurrent recorder count.
- Retention and regional data requirements.
- Whether team members may access original files or proxies only.
- Summary latency target and acceptable cloud-processing cost per match.
