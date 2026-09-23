# Camelot web client

Browser port of the iOS/iPadOS app with the same features: projects, camera capture with live event tagging, the recording editor (timeline, clips, events, speed, crop), the analysis workspace (drawing tools, player tracking, effects, field calibration, measurements) and rendered exports. Local-first; the sync engine arrives later and reuses the `outbox` table and the iOS record shapes.

```bash
pnpm --filter @camelot/web dev      # http://localhost:5173
pnpm --filter @camelot/web check    # tsc
pnpm --filter @camelot/web test     # vitest
pnpm --filter @camelot/web build
```

## Stack

- React 19 + TypeScript, Vite, `react-router`, `zustand` for app state.
- **Metadata**: IndexedDB (`src/storage/database.ts`, `repository.ts`) with an outbox for future sync.
- **Media bytes**: Origin Private File System with an IndexedDB fallback (`src/storage/media-store.ts`). Video never goes through the sync API.
- **Video**: [mediabunny](https://mediabunny.dev) for demux/mux/probe/thumbnails and export, WebCodecs for decode/encode, `<video>` for baseline playback.
- **Heavy work**: Web Workers with a typed job protocol (`src/workers/protocol.ts`). Vision algorithms compile from Rust (`crates/camelot-vision`) to WASM and run inside workers; TypeScript fallbacks keep features working when WASM fails to load.
- **Design**: `src/design/tokens.css` mirrors `DesignSystem.swift` (`Theme.signal`, `Theme.brand`, ink stack, radii, spacing). Library surfaces follow the saved appearance; camera/editor/player set `data-surface="dark"`. `useLayoutMetrics` replaces `AdaptiveLayout` (`isLandscape`, `isWide`, `isShort`, `gridColumns`).

## Layout

```
src/app         shell, router, app-state, appearance
src/design      tokens, components, icons, formatting, layout metrics
src/domain      plain-data records and manifests (ports of Models.swift, AnalysisAnnotation.swift, …)
src/storage     IndexedDB repository, OPFS media store
src/media       mediabunny wrappers: import, probe, thumbnails, frame decode, export mux
src/workers     protocol + client/host helpers; one worker module per domain
src/features    one folder per screen/domain (projects, project-detail, camera, editor, analysis, player, account, onboarding)
```

Conventions: coordinates are fractions of the source display frame (`{x, y}` objects); times are seconds; IDs are uppercase UUID strings. Manifest field names match the Swift `Codable` keys so records translate 1:1 when sync lands. Pure model/geometry code lives outside React components so workers and tests can import it.

## Extending the UI

Add tokens to `tokens.css`, components to `src/design/components.tsx`, icons to `src/design/icons.tsx`. Screens read `useLayoutMetrics()` and pick portrait/landscape arrangements from the actual container size, never from user-agent sniffing. New tools/effects/sheets in the analysis workspace register in their tool registry rather than adding switch cases in the overlay.
