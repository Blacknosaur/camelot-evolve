# Project opening performance — 20 September 2026

## Finding

The project library repeatedly decoded full `CompositionClip` arrays inside view construction to compute duration, clip count, event membership, preview source and local availability. These arrays include every saved tracking sample, appearance memory and annotation. The compact phone layout also built every video row eagerly.

The existing Editor stress test contains 17 videos, including nine saved edits with ten clips and 4,418,600 bytes of edit JSON. One full decode of the edits took 65–71 ms on the physical phone, and screen construction repeated that work. Reopening the screen still took about 843 ms.

Thumbnails already use bounded memory and disk caches in `VideoThumbnailService`; they are generated on cache misses rather than on every project open. Thumbnail code was not changed in this fix.

## Change

- Decode only clip source IDs, source ranges, playback rate and freeze duration for library metadata. Tracking and annotation objects are constructed when editing needs them.
- Cache summaries by composition ID and exact manifest contents, with a 64-entry / 32 MB cache budget. An edit or sync update invalidates the entry even when its mutation ID has not changed. Failed decodes also recover when the manifest changes.
- Use these summaries for project previews, video rows, search, availability checks and choosing the source before opening an edit.
- Build compact video rows with `LazyVStack` so offscreen rows do not all perform their work during opening.
- Keep the saved schema, full editing decoder and render revision behavior unchanged.

## Physical-phone comparison

Release builds, serial runs on the user's iPhone 16, with the same copied stress project in Camelot Review:

| Measurement | Before | After |
| --- | ---: | ---: |
| First project-screen layout | 863 ms | 116 ms |
| Reopening layout | 843 ms | 80 ms |
| One full edit decode, diagnostic | 65 ms | 68 ms |
| One lightweight summary decode of all edits | — | 11 ms |

The layout measurement spans hosting-controller construction, window presentation and `layoutIfNeeded`. It measures synchronous screen construction, not physical tap-to-interactive time, navigation animation or the time until every thumbnail finishes. Both runs retain normal thumbnail caches; this is not a cold-storage benchmark. Two presentations per build are sufficient to demonstrate this bottleneck's reduction, not a distribution across devices and project sizes.

**15 targeted tests passed, zero failures.** Checks cover summary timing, legacy defaults, cache invalidation, malformed manifests, search/filter behavior, edit persistence and render invalidation. Phone-rendered before/after screens were inspected. The existing project was opened with a read-only model configuration, with no project edits saved.

Evidence: `/tmp/camelot-project-open-baseline2.xcresult`, `/tmp/camelot-project-open-improved.xcresult`, their `.log` files, and `/tmp/camelot-project-open-improved-attachments`. The first profiling attempt had an isolated test-host environment error; the baseline above is the corrected successful run.

The verified Release build was installed and launched as **Camelot Review** on the phone using Blacknosaur SC signing.
