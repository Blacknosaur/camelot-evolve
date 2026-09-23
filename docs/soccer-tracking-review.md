# Soccer tracking review — 20 September 2026

## Architecture decision

Use one identity and motion tracker, with optional body segmentation for effects. The on-phone comparison does not support treating the old v2 as a more accurate identity tracker. Its masks are useful visual output but expensive, and were being allowed to overwrite the tracked body. The follow-up removes the Fast / Body mask mode selector: there is one tracking mechanism and an optional **Generate body outline** toggle. Persisted `v1`/`v2` values still decode as legacy mask metadata.

The pipeline has five separate responsibilities:

1. Detect visible bodies and follow their motion at up to 30 samples/second.
2. Preserve player identity, observations, missing intervals and user corrections across passes.
3. Estimate hidden body extent for edge-aware appearance sampling and effect placement, without presenting that extent as measured feet.
4. Track camera image motion and combine it with an independently reviewed ground calibration.
5. Optionally segment the selected body at up to 15 samples/second, using a stable crop and bounded temporal memory.

Leave body outlines off for rings, spotlights, arrows and ordinary tracking. Enable them for effects that need an outline. A mask is not proof of identity or a source of metric foot position.

## Defects corrected

| Area | Finding | Change |
| --- | --- | --- |
| Segmentation geometry | The crop aspect formula stretched landscape bodies. | Square crops now have equal pixel dimensions in portrait and landscape. |
| Segmentation memory | Memory was reused when the crop moved, although its spatial coordinates had changed. | Keep a stable crop while it contains the player; reset and re-prompt when it changes or tracking continuity breaks. |
| Tracking position | A mask could replace the detector/tracker body and move the feet. | Masks are visual output only. Both modes retain the same tracked positions. |
| Tackles | An optical track could move onto the defender between detector frames. | A marginal detector identity match requests another detection sooner. Association combines motion and appearance; recovery after lost continuity requires stronger evidence. |
| Throughput | Segmentation ran on almost every tracking frame; silhouette lookups scanned the whole track. | Bound segmentation to 15 Hz; binary-search the small time window for mask lookup. |
| Learning | Cropped, mixed or conflicting bodies could alter identity memory. | Learn only from clear, compatible, complete observations; do not carry stale auxiliary cues when an unconfirmed identity is reset. |
| Teammates | A unique missing player or a full inferred team could force a same-kit merge. | Remove those assumptions. Offscreen and long absences need individual evidence, repeated confirmation and exclusive assignment. |
| Short dropout | A provisional fragment could claim a body before its established identity checked recovery. | Assign established visible identities first, recovering established identities next, provisional tracklets last. Provisional bodies remain eligible for return-number checks. |
| Recovery suggestions | Selecting one candidate per moment discarded plausible teammates. | Retain multiple distinct bodies, suppress repeated views of the same body, cap retained thumbnail memory, and expose Show frame. |
| Partial bodies | Cropped rectangles could change association scale; a partial seed had no effect extent. | Use separate complete-body estimates. Offline effects can use a later complete observation within the same continuous identity segment. |
| Measurements | Hidden feet and display holds could contribute to speed. | Suppress metric speed where feet or tracking are missing. |
| Camera transforms | Equivalent homographies with different scales could interpolate incorrectly. | Normalize and validate matrices before interpolation. |
| Camera drift | Chaining short scene anchors accumulated error after a pan away and back. | Re-register against the original reference when sufficient scene overlap returns, with rolling/adjacent fallback. |
| UX | Pipeline version names implied an accuracy upgrade and recovery controls hid context. | Use task-oriented mode names, explicit processing states, full-body candidate thumbnails and visible frame-preview controls. |

## Initial physical-device evidence

These results precede the unified controls and manual review follow-up below.

Release builds with testability enabled, serial sessions on the user's iPhone 16, using the existing 33-second, 1920×1080 soccer recording. All runs used a separate company-signed app with a copy of the original project.

| Measurement | Before | Final phone run |
| --- | ---: | ---: |
| Fast tracking, source 3–9 s | 2.6 s | 1.7 s |
| Body-mask tracking, source 3–9 s | 24.4 s | 8.1 s |
| Body-mask samples in that pass | 173 | 81 |
| Player samples in either mode | 180 | 180 |
| Lost during that six-second pass | No | No |
| Worst checked camera landmark error, at 1080p | 16.38 px | 3.76 px |
| Camera pass, source 3–32.9 s | 8.53 s | 1.63 s |

These are individual end-to-end runs, including model work, not a statistically controlled device benchmark. Model warmth and thermal state can change timings: an earlier revised run took 1.2 s / 12.3 s for Fast / Body mask. The mask cadence reduction intentionally reduces stored masks; lookup uses nearby valid masks without bridging missing sections or corrections.

**Final verification: 124 tests passed, zero failures, on the physical phone.** Both modes agreed at IoU > 0.95 every 0.1 s in the compared segment. Feet were also checked against independently read source-frame coordinates at 3, 5, 7 and 9 seconds. Real-footage checks cover opponent crossings, backward tracking, earlier corrections preserving later effects, clipped bodies, and grounded preview/export placement. The number-9 search returned 12 suggestions in about six seconds; direct source review confirmed that the list includes number 9 around 25.07 and 26.67 seconds.

The first revised phone suite exposed the original camera drift and prompted the reference-anchor change. A whole-roster comparison exposed provisional tracklets blocking established identities during recovery. Source-frame inspection also invalidated the old assumption that the single-player tracker was ground truth through the tackle: at 9.8 seconds the blue carrier is near x=0.614, while the white defender is near x=0.564. The regression now checks the source-frame location. The former fixed track-count assertion rewarded forced merges and has been replaced with that identity check; fragment count remains reported.

In the final run, the single-player pass seeded at 3 s deliberately has no confirmed position at 9.8 s and has recovered the blue carrier by 10.0 s. The roster agrees with the single-player track at all 33 compared moments before the tackle, then leaves a longer unresolved gap. It produces 29 tracklets, not 29 distinct people. Its 9.7-second pass took 6.31 s at the thermally reduced cadence of 73 detection frames; this should not be compared directly with a 146-frame pass. Broader gates that rejected every overlapping appearance change were tested and discarded because they lost valid forward/backward coverage.

Local evidence: `/tmp/camelot-soccer-final10-phone.xcresult`, `/tmp/camelot-soccer-final10-phone.log`, and `/tmp/camelot-soccer-final-attachments`. The baseline result is `/tmp/camelot-soccer-baseline-phone.xcresult`. These temporary paths are local diagnostics, not permanent repository fixtures.

Two physical UI test attempts failed before executing any walkthrough: XCTest timed out enabling automation. A direct phone screenshot also showed the new review app’s local-network permission prompt. This does not invalidate the completed physical tracking/render tests, but it is not a passing UI walkthrough.

## Camera and field placement

Image motion, pitch calibration and a physical 3-D camera are different quantities. Keep the shared image-motion track as the source for all field and drawing warps. A reviewed ground plane supplies metric coordinates. Two points supply a local scale only; they do not constrain a full projective field. Four suitable ground correspondences or visible field-line constraints are needed for a ground homography. A fitted centre-circle ellipse needs the actual centre or another field constraint to resolve perspective; its image centre alone is insufficient.

Prefer the clearest source frame with well-spread painted field markings. Review the proposed lines and venue dimensions before treating lengths as measured. Missing camera coverage should hide unsupported projections rather than freeze an old pose. Elevated effects remain dependent on the app's ground/height model; the camera-motion pass is not a recovered calibrated 3-D camera.

## Remaining limits and next model work

- The bundled detector is the E-BARD basketball RF-DETR nano conversion described in `clients/ios/Camelot/Resources/Models/MODEL_NOTICE.md`. It detects people in this clip, but this is not a validation on representative soccer footage.
- Vision image feature prints, kit colour, hair and socks help reject mismatches. They cannot establish every individual's identity after a long offscreen interval. Confirmed jersey numbers and several consistent sightings permit automatic return; otherwise the UI asks the user to choose a candidate while retaining the saved player identity.
- The source number 9 leaves the frame around 2.46 s. The system does not read a confirmed number on that pass. Fully automatic recovery is consequently not proven or promised. Candidate confirmation is still necessary.
- Full-body extent is an estimate. A player who is clipped in every available observation has insufficient evidence for exact hidden feet. No fabricated metric speed is emitted in that case.
- Body-mask contours remain coarse on small or motion-blurred players. They are optional visual output, with box fallback when mask quality or body agreement fails.
- Whole-roster tracking can fragment an unidentifiable return into another provisional tracklet. Avoiding an incorrect merge takes priority over forcing a fixed roster count. The existing 48-tracklet limit also makes this a clip-analysis feature, not a validated full-match roster service.
- No claim of zero identity switches, production-wide accuracy, or “perfect tracking” follows from one video. Measure IDF1/HOTA, identity switches, reacquisition precision/recall, foot/field reprojection error, runtime and peak memory on several annotated matches before choosing a replacement model.

The next substantive accuracy gain should be a soccer-trained detector plus a soccer person re-identification model and temporal jersey reading, evaluated on held-out matches. A model swap without that evaluation could regress small players, occlusion and device speed. [SoccerNet's game-state benchmark](https://github.com/SoccerNet/sn-gamestate) separates these soccer-specific tasks; [BoT-SORT](https://arxiv.org/abs/2206.14651) supports combining motion, appearance and camera compensation. [EdgeTAM](https://github.com/facebookresearch/EdgeTAM) is a video segmentation model; its published device throughput is not the throughput of this app's Core ML integration.

## Installation and data

Blacknosaur SC signing team: `9V4MJ8TDVJ`. Test app: **Camelot Review**, `com.blacknosaur.camelot.evolve.review`.

The original app uses a different signing-team prefix, so iOS rejects a direct company-signed replacement. It was not uninstalled. Its Documents, SwiftData store and preferences were backed up locally before testing; a copy was installed in the review app. The added UI walkthrough is written to cancel edits, but automation never reached it. Repository-wide signing settings were not changed; the review build uses a temporary generated Xcode project.

The verified Release build was installed and launched as Camelot Review after the final test run. Its local-network prompt still needs to be dismissed on the phone before the blocked UI walkthrough can be retried. The original stress project was not edited or saved during this work.

## Follow-up: one tracker and manual frame review

The user's subsequent report of switches prompted a fresh repository/paper review and new tests. See [Football tracking research](football-tracking-research.md), including the actual Vision/OSNet retrieval probe. The initial test totals above are historical evidence, not verification of this follow-up.

### Implementation

- `SelectedPlayerTracking` exposes one motion/identity path with `includeBodyMasks`, defaulting to false. The UI removes the engine picker and second Track button. The old enum survives only as persisted mask metadata for existing projects.
- Appearance learning stops near a similar rival or a contested roster assignment. The original trusted gallery reference remains, invalid embeddings are rejected, and gallery cadence handles out-of-order replacement times and backward passes. A final score cap preserves small appearance differences that additive cues previously saturated.
- New passes set `hidesUncertainPositions`: unresolved gaps stay hidden through storage, effect binding, preview and export. This also takes effect when replacing an older track whose effect had automatic bridging enabled. The user can explicitly enable **Estimate missing positions**.
- **Review frame by frame** enters a paused selection mode. Tap a current detection, tap the player's centre using the previous body size, or draw a new box. Each placement advances one source-rate frame. Back, Next and Undo stay available; Done exits; Track resumes automatically from the last manual placement.
- Input is held while the video seeks, stale detections are hidden, and switching tools/players ends review. Frame stepping supports fractional rates and does not step beyond clip Out. It uses the source's nominal frame rate; exact variable-frame-rate sample traversal is not implemented.
- Manual anchors remain distinct at 60/120 fps, clear obsolete masks, survive roster updates, and bound subsequent repairs in both directions. A backward repair preserves saved tracking outside its completed section.

### Rejected trials

Forcing appearance to remain close to the first reference, penalizing every nonidentical embedding heavily, and increasing detector frequency on any weak cue all reduced coverage on the actual clip. These trials were reverted. The final detector schedule retains the combined appearance test. The small first-frame player recovers after a hidden gap from 5.662 to 6.028 s and reaches 13.967 s with 409 samples in the focused phone test. No identity threshold was relaxed to make that test pass.

### UI verification limit

The physical UI runner again failed before executing a test: **Timed out while enabling automation mode** (`/tmp/camelot-unified-ui1.xcresult`). Device Hub accessibility also timed out. Therefore the tap → advance → undo gesture walkthrough is not verified. Isolated phone-hosted render checks exercise the actual tracking sheet and frame-review controls without loading or saving project edits. Model tests cover frame stepping, manual storage and repair boundaries; they do not prove the complete gesture flow.

### Final follow-up verification and installation

**87 tests passed, zero failures, on the physical iPhone in 86.8 seconds.** This run covers identity association, real soccer crossings/tackles, distant-player recovery, backward tracking, shared effects/storage compatibility, incremental repair, manual anchors, and phone-rendered controls at 360/744 points. The controls and source-frame overlays were visually inspected after export. No blanket zero-switch claim follows from this one recording.

The source 3–9 s comparison produced 180 player samples with either outline setting, with no loss/gaps and position agreement above 0.95 IoU. Without outlines it took **1.2 s**; with outlines **14.0 s**, producing 81 masks. These are individual runs, not a controlled speedup comparison with the earlier measurements. Body outlines remain optional and coarse on small players.

Evidence: `/tmp/camelot-unified-final-phone.xcresult`, `/tmp/camelot-unified-final-phone.log`, `/tmp/camelot-unified-final-attachments`. Release build logs are `/tmp/camelot-unified-build5.log` and `build6.log` (the latter changes only the isolated render test's dark-mode environment).

The verified app was installed and launched as **Camelot Review**, bundle `com.blacknosaur.camelot.evolve.review`, signed with Blacknosaur SC. A launch screenshot confirms the Projects screen with Editor stress test visible and no permission prompt. The original app was not replaced and the existing stress project was not saved or modified by these tests.


## Follow-up: confirmed identity views and reliable corrections

See [Player identity and frame review](player-identity-and-review.md) for the later fixes to playhead tracking, correction boundaries, tap selection, automatic frame advance, confirmed front/back/side references, manual jersey numbers and shared identity across effect/connection tracking. That report contains the latest physical-device verification; earlier results and UI automation blockers above are historical.
