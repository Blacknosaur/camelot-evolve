# Temporal recovery and explicit redo — 20 September 2026

## Reproduced failures

The full 32.5-second soccer fixture was replayed on the physical iPhone with an explicit first-frame selection of the distant blue ball carrier. Source frames were inspected, not just compared against another tracker.

- Baseline: after losing the carrier at 24.705 s, recovery extrapolated his previous running velocity while he stopped. It ignored a good observation at 25.138 s on the next detector frame, continued searching too far right, and took a different blue teammate around 26.87 s. Runtime: 11.83 s. The wrong teammate eventually left the frame at 29.04 s.
- The existing late-crossing test skipped assertions when the track was missing and only checked x < 0.78. That let missing coverage and a white defender near the bound pass. It now requires recovery at source-checked positions.
- Manual frame-review placements were protected repair boundaries. A normal automatic pass could stop at the next reviewed frame. The whole-clip action was also hidden after complete coverage.

## Implementation

Recovery retains a short-lived, identity-gated candidate observation as the next search position, compensated for camera motion. The candidate still needs repeated agreement before it becomes confirmed tracking. Candidate hints expire or reset on rejection. Old velocity is extrapolated for at most 0.75 seconds; searching continues beyond that horizon.

An intermediate version reduced missing time but followed a white defender during the next crossing. The final candidate adds a bounded run of weak clothing evidence: sustained weakness after a recent player overlap restores the last trusted motion and removes the uncertain tail before recovery. Short isolated fluctuations keep the existing tolerance for turns.

Explicit Redo is available in the tracking sheet and the frame-review Track menu. It takes a section or the full clip, removes manual boundaries inside that range, and asks for a fresh player selection. Tracking runs within the requested range in both directions from the selection. Samples outside the half-open range, player identity references, and other players are preserved. Stopping leaves unfinished frames untracked; Undo restores the prior track. Normal repairs continue protecting manual picks.

## Research context

[OC-SORT](https://arxiv.org/abs/2203.14360) describes drift from extending old linear motion through occlusion and uses observations to correct it. [BoT-SORT](https://arxiv.org/abs/2206.14651) combines motion, appearance and camera compensation. This change applies those principles in the existing native tracker; it does not import either implementation or claim their published benchmark results.

## Verification

- The first complete verification run passed **101 tests, 0 failures**, on the physical iPhone (`/tmp/camelot-temporal-final-phone.xcresult`). This included nine soccer-footage cases, shared bindings, incremental forward/backward tracking, identity, manual repair, and optional masks.
- The new source-checked full-clip replay took **7.63 s** for 32.5 s of video. It reached 32.477 s without terminal loss. Five hidden intervals remained: about 0.30, 0.43, 0.30, 0.57 and 0.83 seconds. Recovery stayed with the original carrier at 25.5, 27, 28 and 30 s; it no longer took the right-wing blue teammate or the white defender in these checked cases.
- The late-crossing regression now requires a visible, correctly located blue carrier at 27, 27.5 and 28 s. It cannot pass merely by hiding all those frames.
- A real-footage redo crosses nine old manual placements and replaces the selected 4–6 s range while preserving original samples outside it. Synthetic cases cover incomplete replacement, old terminal loss, and retained identity.
- The range selector and tracking sheet were rendered in a real hosting window on the phone and inspected. The compact review menu is captured using a hosting window too; SwiftUI ImageRenderer cannot render the native Menu button correctly.
- A small missing interval at the join of a full redo's backward and forward halves was found during review and fixed. That additional regression passed on the final app build.

Final verification exercised **102 distinct device test cases**. All tracking/identity/replacement cases passed. The only failure was the updated native-control screenshot fixture counting the hosting window's safe-area padding in both width checks. Its hosting window was corrected without changing app code; the targeted rerun passed at both 360 and 744 pt, and the actual native Track menu was visually inspected. Final app/integration results: `/tmp/camelot-temporal-verified-phone.xcresult`; corrected screenshot rerun: `/tmp/camelot-temporal-controls-phone.xcresult`. Builds 4–6 succeeded; only the screenshot fixture changed between the last builds.

The interactive tap/redo walkthrough was blocked before it ran: iOS displayed **Enter iPhone Passcode for XCTest — Enable UI Automation** and the runner timed out. The user was asked to complete the prompt on the device. Screenshot: `/tmp/camelot-temporal-ui-state.png`; result bundle: `/tmp/camelot-temporal-ui.xcresult`.

No test saves edits to the user's stress project. The original recording is only read.

## Limits

These are source-checked regressions on the available soccer recording, not a claim of perfect tracking across matches. Brief genuinely ambiguous overlaps remain hidden. Long offscreen returns without distinctive individual evidence still need confirmation; jersey colour and a generic body print do not uniquely identify teammates. Existing saved trajectories must be redone to apply the new recovery logic.

## Installation

Installed the verified Release build as **Camelot Review**, `com.blacknosaur.camelot.evolve.review`, using Blacknosaur SC signing. The original Camelot app was not replaced. Install log: `/tmp/camelot-temporal-install.log`. Installation URL ends in `79C4EE7D-0033-4B76-9088-CA0573A68FF3/Camelot.app`.

Launch succeeded (`/tmp/camelot-temporal-launch.log`). A device screenshot confirmed the Projects screen with the existing stress project visible: `/tmp/camelot-temporal-installed.png`.
