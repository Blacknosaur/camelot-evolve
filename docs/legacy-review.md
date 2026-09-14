# Legacy review

The previous repository was reviewed for product vocabulary and failure signals, not copied.

Useful concepts to retain:

- projects containing media, edits, documents, folders, and event sets;
- device-local and remote media representations;
- native video-editor modules alongside cross-platform UI;
- organization/group sharing and configurable event templates;
- thumbnails, drawings, exercises, and summary rendering.

Patterns not carried forward:

- AWS DataStore models with most domain structure embedded as unvalidated JSON;
- owner-only authorization for content that must be shared across organizations;
- direct cloud credentials and signing logic in clients;
- metadata synchronization coupled to file upload/download hooks;
- mutable arrays mixing local paths, device IDs, and remote object keys;
- UI components owning transfer, persistence, and rendering concerns;
- one cross-platform media stack as the performance-critical implementation.

Before migration, build a read-only inventory exporter from the legacy backend and validate counts/checksums. Do not make the new model match legacy storage defects merely to simplify import.

