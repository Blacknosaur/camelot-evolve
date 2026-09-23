# Player identity and frame review — 20 September 2026

Follow-up: [temporal recovery and explicit section/whole-track redo](temporal-recovery-and-redo.md).

## Changes

- Tap selection prefers the body containing the point over a neighbour's padded target; overlapping candidates are ranked by proximity to the tap. This fixes a thin duplicate detection at 3 s in the soccer fixture.
- A pick tolerates 12 points of finger movement before becoming a box drag. An undersized selection drag falls back to a tap. Touches begun during a seek cannot place a player on a different frame.
- Review keeps one manual placement per source-rate frame and advances immediately. Detector results refresh when the current review frame has no matching detection; the previous body size remains available for a centre tap.
- Track forward/backward starts at the requested playhead. A missing seed asks for a selection there instead of silently moving to an older or later frame.
- Fix invalidates the automatic section up to the next manual anchor. Stopping or losing the player cannot restore that section's old wrong trajectory. The playhead follows the actual pass result.
- Tracking no longer stops early merely because it briefly agrees with an old trajectory. The next manual boundary still protects authored corrections.
- Explicit picks rebuild contaminated automatic appearance cues. Confirmed front, back, left-side and right-side references remain separate, bounded and persistent. Safely learned intermediate poses support turns between those views.
- Confirmed kit appearance constrains matching. The combined confirmed/learned appearance gallery can reject a same-kit mismatch; generic appearance alone still does not prove identity after an offscreen exit.
- The tracking sheet lets the user add or replace each view and enter a jersey number. A manual number survives restarts and noisy OCR.
- Head colour, crown/hair colour and visible face colour are separate observations. Hair/face sampling requires enough source pixels; visible-face colour additionally requires a confident face detection. Missing detail contributes no evidence. These are supplementary visual cues, not demographic classifications.
- Effect and connection snapshots restore identity from the shared player library before tracking. Whole-clip direction changes preserve that same memory.
- Full-body outlines remain optional and use the same tracker.

## Rejected intermediate approach

A strict comparison against the manually confirmed view alone lost the blue runner at 6.2 seconds when he turned. The final approach retains clear automatically learned views alongside confirmed references, while constraining both by confirmed kit appearance. Keeping the synthetic same-kit impostor test ensures an unqualified automatic shirt match cannot bypass a clear appearance disagreement.

## Verification

Physical iPhone 16 (MM), Release build, Blacknosaur SC signing:

- **95 tests passed, 0 failures** in 79.46 s: roster/identity, repair, incremental tracking, shared tracks, optional masks and eight actual soccer-footage regressions.
- A manually confirmed repair, starting with deliberately wrong automatic white-kit memory, produced 180 samples over 3–9 s in **1.16 s**. The actual white opponent could not contaminate its corrected memory. Source-frame contact sheets at 3, 5, 6.5 and 8 s were visually checked.
- The distant first-frame selection reached 13.967 s without terminal loss, with two explicitly hidden gaps (0.30 s and 0.433 s). This is conservative coverage, not a claim of uninterrupted certainty.
- Source-checked blue/white crossing and tackle cases passed. A white player's 0–1 s continuity among white teammates also passed; this is not a long-absence same-kit reacquisition benchmark.
- Ten placements against the real AVPlayer advanced ten distinct source frames and preserved all ten manual anchors. Compact review controls and the identity view/number section were rendered and inspected on the phone.
- Legacy decoding, manual-number persistence, multi-view round trips, hair/face-cue scoring, protected anchors, restored identity for effect bindings, and the thin duplicate tap regression passed.

Result bundle: `/tmp/camelot-identity-review-final-phone.xcresult`; build log: `/tmp/camelot-identity-review-build8.log`.

Tests use in-memory clips and the existing soccer recording, without saving edits to the stress project.

### UI walkthrough and installation

The final gesture walkthrough was blocked before execution: iOS displayed **Enter iPhone Passcode for XCTest — Enable UI Automation**, and the runner timed out enabling automation. The user was asked to complete that prompt on the phone. The actual tap-with-drift / auto-next / Undo walkthrough is therefore **not yet verified**. An earlier UI attempt navigated the project but stopped at an offscreen lazy row; its helper now scrolls to the recording.

The final verified Release build was explicitly installed and launched as **Camelot Review**, `com.blacknosaur.camelot.evolve.review`, using Blacknosaur SC team `9V4MJ8TDVJ`. The original app was not replaced or uninstalled. Install and launch logs: `/tmp/camelot-identity-review-install.log`, `/tmp/camelot-identity-review-launch.log`. Blocked UI result: `/tmp/camelot-identity-review-final-ui.xcresult`.

## Limits

This remains an on-device combination of motion, kit features, Vision body feature prints and jersey OCR. It is not a newly trained soccer ReID model. Front/back/side labels come from the user's explicit selection. Small, blurred or occluded faces often provide no usable hair/skin evidence. An ambiguous teammate returning without a readable number still needs manual confirmation.

Frame stepping uses nominal source frame rate; variable-frame-rate sample traversal is not implemented. The soccer clip and targeted fixtures are regression evidence, not proof of zero identity switches across matches.

Face rectangles use Vision's normalized image coordinates with a lower-left origin, converted before sampling. [Apple's bounding-box documentation](https://developer.apple.com/documentation/vision/vndetectedobjectobservation/boundingbox).
