# Camelot Evolve

Native-first, offline-first video analysis for sports teams.

This repository starts with the shared backend and sync protocol. The iOS, Android, web, and Rust clients will consume the same versioned wire contract while keeping platform-native storage and media pipelines.

## Local development

Requirements: Colima, Docker, Node 22+, and pnpm 10.

```bash
colima start
docker compose up -d postgres minio
cp .env.example apps/api/.env
pnpm install
pnpm db:migrate
pnpm dev
```

Or run the complete stack in containers:

```bash
colima start
docker compose up --build
```

Check `http://localhost:3000/api/health`. MinIO is available at `http://localhost:9001`; the Compose API uses it through the same S3 interface used by R2 and other compatible providers.

## Repository layout

- `apps/api`: stateless Hono API and Better Auth entry point
- `packages/db`: PostgreSQL schema and migrations
- `packages/sync-contract`: runtime-validated sync wire contract
- `crates/camelot-sync-core`: future portable Rust sync state machine
- `apps/web`: browser SPA with the same features as the iOS app (React, IndexedDB/OPFS, mediabunny + WebCodecs, WASM workers); see `apps/web/README.md`
- `crates/camelot-vision`: image-processing kernels compiled to WASM for the web client
- `clients/ios`, `clients/android`: native client implementation boundaries
- `docs`: architecture decisions and delivery plan

## Commands

```bash
pnpm check
pnpm test
pnpm build
pnpm db:generate
pnpm db:migrate
```

Do not put video bytes through the sync API. The sync API moves small metadata records; resumable object-storage uploads are a separate lifecycle.
