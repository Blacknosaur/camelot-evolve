# Annotation and on-device analysis

## Task-first Analyse workspace — 23 September 2026

The Analyse screen was rebuilt for coaches with little editing experience. The
engines (single-player tracking, pitch registration, camera motion, rendering and
the saved clip format) are unchanged; the screen around them is new.

- **One top bar:** close (asks before discarding edits), Undo, Redo, Done.
- **The video gets the height the footage needs** in portrait; the rest goes to
  the timeline and one bottom bar. Dragging the divider still resizes.
- **The bottom bar shows exactly one thing:** at rest, five labelled tiles
  (Player, Draw, Text, Zoom, Pitch); during a task, its palette or a one-line
  instruction with Cancel; with something selected, that item's actions.
- **Player:** tap a player (or draw a box) → a sheet of big toggles (Ring,
  Spotlight, Name, Trail, Magnifier) with a few style chips and six colours →
  Add. The highlight appears at once on a one-frame track and the pass then
  follows the player forward (the video runs along, like playback) and back to
  the clip start. The track is stored every 0.4 s, so the highlight itself
  moves with the player while it runs. Stop keeps everything so far.
- **Player bar:** name (tap to rename), Highlight, Fix, ⋯, and a strip showing
  where the player is followed (lime) and lost (orange); tapping the strip
  seeks. **Fix** is the only repair: go to any frame where the player is
  visible and tap them. Inside a lost part only that part is filled (forward to
  its end, then back to its start, never overwriting kept tracking); on a frame
  that was followed the track was on someone else, so it re-follows from there
  (the existing correction path, bounded by later manual picks).
- **Draw:** Arrow, Line, Pen, Circle, Box, Area, Connect, Magnifier plus colour
  swatches. A selected drawing shows Movement (Stays put / Stick to the pitch /
  Follow a player / Animate by hand), Style and ⋯ (play, start/end here,
  duplicate, lock, delete). Style is one page: colour, Thin/Medium/Thick, the
  shape's effect, measurements and "When it shows".
- **Pitch** opens "Line up the pitch", which starts detecting on open and ends
  in **Looks right** / **Try again**; the method menu, handles, nudges, loupe
  and dimensions are under **Adjust by hand**. Asking for distances or speed
  without a pitch opens it.
- **Removed from the UI** (engine code kept): Track all players, tracking
  directions (forward/backward/fill gap), frame-by-frame review, redo-a-section
  ranges, identity references and shirt numbers, body outlines, team
  assignment and linking, gap-bridging and smoothing sliders, the saved-tracks
  list, timeline zoom buttons. Defaults: new tracks hide uncertain positions
  and keep the default smoothing.
- Detection failures no longer raise an alert; a note suggests drawing a box.

Verification: `CamelotUITests/AnalysisWalkthroughUITests` seeds its own
"UITest Analyse" project, walks every state and saves screenshots
(`TEST_RUNNER_CAMELOT_SAMPLE_VIDEO`, `TEST_RUNNER_CAMELOT_SHOTS_DIR`), then
removes the project. Vision does not run on the simulator, so live following
and Fix need the phone.

## One-second gaps and identity-gated returns — 21 September 2026

The automatic interpolation ceiling is now 1 second between confirmed endpoints;
all position, scale, frame-boundary, correction and terminal-loss guards remain.

The remembered edge no longer accepts a matching shirt as return evidence.
After an exit, each temporal confirmation needs a matching number or learned
appearance; proximity to a pending candidate cannot substitute for identity.
An optional, bounded upper-body appearance gallery stores clear head/torso views
using the existing on-device Vision feature printer. Recovery compares the same
visible region against those references, including when the legs are cropped.
Partial observations cannot teach the gallery. A strong upper-body match is not
vetoed merely by a changed whole-body pose; number, kit and tone conflicts still
apply. Missing or incompatible appearance leaves the player untracked.

Simply removing the shirt shortcut regressed the May 11 test, and requiring both
whole-body and upper-body embeddings delayed the second return to 24.54 seconds.
The final regional matching path passed 62 focused Release tests on MM in
`Test-Camelot-2026.09.21_18-05-11-+0200.xcresult`; another 33 shared roster/memory
tests passed in `Test-Camelot-2026.09.21_18-09-17-+0200.xcresult`, with no skips.
The actual May 11 track returns at 9.998 and 21.503 seconds; the prior, less strict
version began at 9.732 and 21.37. The test therefore requires the later return
by 21.6, not 21.4. Correct markers were visually checked at 10.4 and 21.6; absence
checks at 7 and 20.5 and later identity checks at 23 and 25.07 also pass.

Synthetic right-edge tests reject shirt-only candidates, mismatching appearance,
and conflicting numbers. The user's specific right-edge incident still needs
its clip/time to reproduce; these checks do not prove all same-kit returns.
Rerun **Track** to learn the new regional references and recompute recovery.
Tests did not save user-project edits.

## Short-gap display and recovery history — 21 September 2026

Automatic single-player display interpolation now allows up to 0.5 seconds
between confirmed endpoints, retaining the position, scale, frame-boundary and
manual-correction guards. Raw gaps remain missing measurements. Timeline coverage
uses the same display lookup as the preview, so an interpolated interval no
longer appears orange. The existing timeline layout and style are unchanged.

After recovery confirms the winning identity, its recent matching sightings are
saved at their original source times and coordinates. History is bounded to
0.5 seconds / 12 observations; missed frames do not become evidence and competing
hypotheses cannot contribute positions to the winning track. Three sightings
are still required for an offscreen return.

Verification: 60 Release tests passed on MM (iPhone 16), no failures or skips,
in `Test-Camelot-2026.09.21_17-21-27-+0200.xcresult`. May 11 #9 coverage now
starts at 9.732 and 21.37 seconds, versus confirmation at 9.865 and 21.57 seconds.
Rendered frames at 10.4 and 21.4 seconds and the cyan/orange timeline fixture
were visually inspected. The player is still not tracked at 21.2 seconds;
this removes confirmation delay, not the earliest partial-body detection limit.
The real-footage repair test also verifies short-gap interpolation against
observed motion and preserves later tracking and other players. No user project
edits were saved. Rerun **Track** to obtain the earlier recovery samples.

## Exit-side recovery follow-up — 21 September 2026

Single-player recovery now applies the remembered exit edge to both nearby
association and whole-frame fallback. An off-edge candidate needs strong identity
plus a camera-registered last trusted position near that candidate; a pending
candidate cannot provide its own camera evidence. The edge crop is searched even
when another candidate exists or the trajectory prediction is outside the image.
After an exit, detection targets 0.1-second source-video intervals (previously
0.4 seconds when dormant), then 0.06 seconds during confirmation. Three distinct
observations are still required. This increases processing work while missing;
these intervals are not measured end-to-end recovery latency.

The first installed follow-up failed the May 11 regression at 10.4 seconds.
The subsequent fix addresses the causes found in the frame traces:

- Normalize partial and complete association boxes against the same body scale;
  do not replace that scale with a near-bottom crop. Infer a cropped exit even
  when the detector stops at the shirt hem. Keep boundary detections frequent.
- Constrain same-edge returns to the remembered exit region. Only already
  identity-gated returns can bypass the stale pre-exit trajectory's position gate.
- Feed nearby and whole-frame candidates through one confirmation update. A
  missed frame may retain a pending hypothesis for 0.3 seconds, but cannot count
  as evidence: re-identification still needs three distinct matching sightings.
- Whole-body prints qualify re-identification, rather than vetoing continuous
  optical motion every time the player turns. Kit/head cues, continuity and
  ambiguity checks still constrain routine tracking; uncertain views are not
  learned as new identity references.

New single-player passes also enable bounded display interpolation for gaps up
to 0.2 seconds between confirmed endpoints (expanded to 0.5 in the follow-up
above). It rejects frame exits, manual
corrections, large position/scale jumps and terminal losses. Raw measurement gaps
remain intact, cannot seed tracking, and never receive invented body masks. This
flag survives forward/backward updates and gap filling independently of legacy
per-effect bridging settings.

Verification: 58 Release tests passed on MM (iPhone 16), zero failures or skips,
in `Test-Camelot-2026.09.21_15-59-00-+0200.xcresult`. The May 11 test checks #9 at
10.1, 10.4, 21.6, 23 and 25.07 seconds, and absence at 7 and 20.5 seconds. The
trace confirms the later return at 21.57 seconds; rendered frames at 10.4, 21.6
and 23 seconds were visually inspected. This focused run tests the shared
tracking path without body masks, not every player or every possible occlusion.
Rerun **Track** to recompute previously saved tracking with these changes.

## Partial returns and timeline zoom — 21 September 2026

The May 11 #9 regression now checks the actual return around 10 seconds, continued
tracking at 10.4 seconds, absence at 7 seconds, and a drawable effect body after
recovery. A detector box ending at the shirt hem near the lower image edge must
not replace the last complete body proportions. Partial observations are neither
learned as complete appearances nor compared against whole-body feature prints.
Recovery also searches the remembered exit edge and briefly increases detection
cadence while collecting the existing three-frame confirmation.

Rendering must preserve an already estimated, out-of-image body extent after a
confirmed return, even without a new complete sample after the gap. Legacy boxes
clipped exactly to the image boundary still require a complete reference within
the same identity segment; missing tracking itself is never bridged by this rule.

Timeline rows own their width; zoomed bars and trim handles are leading-aligned
overlays, clipped before the timeline's horizontal padding. This preserves the
existing timeline style. The phone UI regression checks 1× through 16× without
saving its temporary drawing. These focused tests do not establish accuracy for
every player or every later re-entry in the clip.

Verification: seven targeted Release tests passed on MM (iPhone 16), followed by
the non-saving Release UI walkthrough at 1×, 2×, 4×, 8× and 16×. Captured frames
show #9's marker at 9.9 and 10.4 seconds; the high-zoom timeline stays aligned and
inside its side margins. Installing the update does not recompute saved tracking:
run **Track** again to replace an old result.

## Incremental player tracking: stop keeps the data — 18 September 2026

Miguel: "for long clips it takes forever and if we cancel the tracking analysis we just lose
everything… it should be sequential doing frame by frame and we can update the playback position
as we go… this would allow us to re-track from a position moving forward until we stop it."

**Measured first (iPhone 16, Release, real footage on the phone —
`CamelotTests/PlayerTrackingBenchmark`).**

Per frame, at 1280 / 960 / 720 decode long side:

| Stage | 1280 | 960 | 720 |
|---|---|---|---|
| decode (1280×720 source) | 6.09 ms | 6.20 ms | 6.04 ms |
| `VNTrackObject` | 1.28 ms | 1.14 ms | 1.02 ms |
| sports detector (two crops) | 20.07 ms | 20.30 ms | 19.89 ms |
| focused retry crop | 9.85 ms | 9.72 ms | 9.65 ms |
| four feature prints | 6.31 ms | 6.54 ms | 6.89 ms |
| one shirt-number read | 24.26 ms | 24.73 ms | 27.66 ms |
| camera registration (recovery only) | 19.23 ms | 19.16 ms | 17.89 ms |
| `PlayerObservation.observe`, jersey signature | < 0.05 ms | | |

Steady-state decode, measured separately over 60 frames: 480p 1.31 ms, 720p60 3.47 ms, 1080p
2.18–2.35 ms, **4K 6.96 ms**, and decoding any of them down to 720 saves at most about a
millisecond.

**A lower-resolution proxy is therefore not worth building.** The detector is the cost, and its
CoreML input is a fixed size with `.scaleFill`, so source resolution does not change inference
time at all; decode is 1–7 ms whatever the source. Neither of the user's long recordings is even
high resolution: the 5½-minute clip is **852×480 at 25 fps** and the 16-minute one is **1280×720
at 59.94 fps**. A proxy would cost a one-off encode and permanent disk for a saving that does not
exist. Rejected, with the numbers above.

**What actually made long clips fail: memory.** A 300-second pass peaked at **2226.6 MB** of
physical footprint, growing linearly with the clip. The per-frame loop had no autorelease pool, so
every Vision and CoreMedia temporary accumulated for the whole pass. Wrapping each frame in
`autoreleasepool` takes the same pass to **144.1 MB peak** — flat. That is the "ends up failing".

**What made it slow.** Throughput on the stress footage is about 2.3× real time while the player
is being followed (≈ 69 source frames per wall second), so five minutes of video costs a bit over
two minutes of tracking. Nothing about that is resolution: it is one `VNTrackObject` plus a
20 ms detector every 0.3 s on every decoded frame. On 60 fps footage that work was done twice as
often for no benefit, since every association gate here was tuned on 30 fps footage.
`PlayerTrackingLimits.maximumSampleRate` now caps sampling at 30 Hz; sources at or below the cap
keep every frame. Interleaved on the phone over the same 10 s of the 60 fps clip in one thermal
state: 60 Hz 3.14 s / 448 samples, 30 Hz 2.35 s / 276 samples — **1.34× faster**, more where the
player is followed throughout.

**The rebuild.**

- `SelectedPlayerTracking.track(url:seed:from:to:direction:allowRecovery:prior:checkpoint:)` is
  now one incremental API for both directions, returning a `PlayerTrackingOutcome`
  (`motion`, `stopped`). It publishes a `PlayerTrackingCheckpoint` as it goes: the source time of
  the frame just examined, the fraction, and roughly every 0.4 s a complete `PlayerMotion` of
  everything confirmed so far, already mapped back to source time for a backward pass.
- **Stopping is not failing.** The loop checks `Task.isCancelled` and returns the partial track
  with `stopped = true` instead of throwing. Stopping while the player is visible sets no
  `lostAt`: the track simply ends there. The old fraction-only `track(…progress:)` and
  `trackBackward(…progress:)` wrappers remain for the drawing-bound and linked-player paths and
  still throw `CancellationError`, so nothing else changed behaviour.
- **The editor follows the work.** `AnalysisWorkspaceView.runPlayerTracking` is the single entry
  point for every player pass. Each checkpoint moves the preview with `previewSeek` (throttled to
  24 Hz), updates the highlighted box, and every two seconds folds the partial into the clip's
  tracking library, so even a pass killed by something other than Stop leaves its work. The final
  result is always stored, stopped or not.
- **Re-tracking a range needed no new splice.** Forward folds through
  `PlayerMotion.continuing(with:from:)`, which already replaces only the tracked section and
  preserves the saved past *and* future; backward folds through `prepending(_:seed:)`. Re-tracking
  a middle section is therefore just a pass the user stops, in either direction.
- **Backward stayed a mirrored pass.** It decodes 0.5 s chunks with fresh readers and replays them
  reversed in a mirrored time base through the same `run()`. Measured, that costs 2.33× real time
  against forward's 2.31×, so the chunked readers are not a bottleneck and there was no reason to
  risk re-deriving the per-frame logic for a second time base. The mirrored result is mapped back
  to source time by one `unmirror` used for both checkpoints and the final motion.
- **UI.** The tracking bar now shows the direction, the growing tracked range as a timecode span,
  and a **Stop** button (identifier `analysis-stop-tracking`) instead of Cancel. The Tracking sheet
  offers **Track forward from here** and **Track backward from here** from the playhead, next to
  Track whole clip (which is now the two halves in turn, each stoppable), over the existing
  blue/orange coverage bar.
- **The saved format did not change.** `PlayerMotion`, `AnalysisTrackingLibrary` and the clip
  manifest are untouched, so no migration is needed and no existing track can be lost;
  `testTracksSavedBeforeIncrementalTrackingStillDecode` pins that.

**Verification.** 135 tests green on MM / iPhone 16 in Release, zero failures and zero skips,
covering the roster footage, repair, editing, visual-effect, shared-tracking, identity, trajectory,
marker, camera and grounded-effect suites plus the new `IncrementalTrackingTests`: sampling-rate
maths, middle-range replacement forward and backward, legacy decode, and on real footage
incremental publication, stopping keeping the partial track, re-tracking a middle range without
disturbing the rest, and forward/backward agreement 23/23. The user's recordings and analysis
sidecars were byte-identical before and after every device run.

**Limits.** Tracking is still an offline job at roughly 2.3× real time while it is following a
player, so a five-minute range is still a couple of minutes of work — it is now watchable,
stoppable and never lost, rather than faster than real time. Recovery after a loss is decode-bound
and the sampling cap does not help there. `Track all players` (the roster pass) still runs
all-or-nothing; only single-player tracking is incremental.

## Player roster: shared identities, bridged effects and hand placement — 15 September 2026

- **Track all players** runs one shared pass over the clip instead of one
  single-player pass per body. The clip is decoded once; the existing Hoops
  sports detector runs at 15 fps (8 fps under serious thermal pressure), and
  every remembered player is matched in the same frame with an exclusive
  assignment: visible players settle first, returning players may only claim
  bodies no visible teammate owns, and any near-tie hides the player for that
  frame rather than guessing. This is the same conservative policy as the
  single-player tracker, generalised across up to 48 identities (a 20-a-side
  pitch plus officials).
- Each saved player now carries a **roster identity**: the torso histogram used
  before, a second shorts histogram, a voted shirt number and a swatch colour.
  Numbers come from sparse `VNRecognizeTextRequest` reads on large, unoverlapped
  torsos (at most a few per frame, one per player per 0.8 s) and count only after
  three agreeing reads; a confirmed different number is decisive, an unreadable
  one never rejects a matching kit. Identities persist in the tracking library
  (`Player.identity`) and are handed back to later passes as priors, so a
  re-run recognises saved players by kit rather than creating duplicates.
- Missing players are remembered with a camera-relative last position (the clip
  camera track when it covers the frame, otherwise lightweight background
  registration while someone is missing). A player who left the picture can
  re-enter near the exit edge on a strong, unoverlapped kit match; a saved
  player not visible at the pass start is recognised on appearance alone with
  dormant strictness (three confirmations). Predicted positions are never saved.
- Bodies nobody claims start provisional tracklets; they become players after
  half a second of clear, confirmed-kit observations that no remembered player
  contests, and are discarded if they vanish first. Tracks the pass saw much
  less of than an existing saved track keep the saved motion but gain the kit.
- **Effects keep following through losses.** Stored tracks now carry display-only
  bridged positions (`inferred`) for gaps up to 4 s and a one-second hold after a
  terminal loss; each drawing chooses how much of that it shows with the new
  *Bridge missing tracking* slider (0–4 s, new tracks default to 2 s, older
  drawings keep the 0.4 s bridge). With a clip camera track the confirmed
  neighbours are carried through the camera motion first, so a ring stays on the
  grass during a pan instead of sliding across it. Raw samples, gaps, timeline
  orange marks, speed and measurements are unchanged.
- **Fixing untracked places by hand.** A selected saved player shows gap arrows
  (previous/next untracked section) and *Place here*: tap or draw around the
  player to insert an exact, unsmoothed anchor without running tracking. The
  anchor splits the gap, so bridging then runs from the last confirmed sample to
  the anchor and on to the next one. A later Correct pass replaces anchors only
  inside the section it re-tracks. Roster-created players nobody draws with can
  be removed from the tracks sheet.
- Compatibility: `PlayerMotion` gains optional `inferred`, `anchors` and
  `gapBridging`; `Player` gains optional `identity`. Older projects decode
  unchanged and keep their previous display until re-stored or re-tracked.
- Recovery details: players that just dropped out get a zoomed detector crop
  around both hypotheses (still in the scene, or moving with the camera) before
  anyone may claim a nearby body; when several players drop out together the
  crowd's common displacement is estimated and applied; a body followed clearly
  for half a second is compared with the missing players (late
  re-identification) before it becomes a new player; when only one player of
  that kit is missing, the body is that player wherever it appears, and a kit
  never exceeds eleven confirmed players (a twelfth body merges into the most
  plausible missing one or is discarded). Track all runs the shared
  camera pass first when the clip has none, because camera-relative memory
  without it inherits the pan as player motion.
- Limits: identical kits with unreadable numbers still rely on motion and
  exclusivity, so long same-team overlaps can still need Place here or Correct.
  In the stress footage's blurred pan from about 9.5 s the runner moves with the
  camera while a same-kit teammate stands on its camera-relative spot; the
  detector-only roster then hides or switches that identity there (single-player
  tracking rides through on Vision's optical tracker). Number reads need fairly
  large bodies (about 14 % of frame height) and are a disambiguator, not a
  labelling feature. The pass is not real time.
- Verification: all **242 `CamelotTests` passed on MM / iPhone 16 in Release**
  (`/tmp/roster-phone-final.xcresult`, log `/tmp/roster-phone-final.log`),
  including 12 new `PlayerRosterTests` (exclusive assignment, edge re-entry,
  numbers, memory resumption, roster discovery across a hidden second, priors,
  camera-aware bridging and hold, hand placement, gap navigation, legacy
  decoding, library merge/remove) and the real-footage `PlayerRosterFootageTests`:
  24 players over 3–12.7 s in about 7 s (with the clip camera track and the
  zoomed recovery crops), the seeded runner agreeing with single-player tracking
  on every compared frame before the pan and keeping its identity to the end of
  the clip, and a second pass recognising saved players by kit instead of
  re-creating them. Kit colour histograms are weak under floodlights (blue and
  white shirts both read as neutral), which is why the per-kit cap and the
  unique-missing rule, not colour alone, limit duplicates; a chromaticity gate
  was tried and rejected because floodlit blues vary too much. `AnalysisEditingTests`' crossing check now only asserts
  hidden midpoints for gaps longer than the 0.4 s display bridge, which that
  later feature had made inconsistent. The same Release build was installed and
  launched on MM at 10:34 Europe/Madrid on 15 September 2026. Pure-logic
  tracking classes also pass on the arm64 iPhone 17 Pro simulator; the generic
  x86_64 simulator build fails on a pre-existing `GroundShapeGeometry` operator
  ambiguity unrelated to this work. The macOS `CamelotShared` copies were not
  updated (they already diverged before this change).

## Analysis workspace: tools behind one button, one bottom row — 15 September 2026

- Drawing tools moved out of the workspace into a **Tools** toolbar button (icon
  = current tool) that opens a grid sheet with the same tool identifiers plus
  Measure and Field. The bottom row of the workspace now shows exactly one of:
  the running pass (progress + Cancel), the player pick/place prompt, the picked
  player's row (effects, gap arrows, Place here, Correct), the selected layer's
  controls (motion mode / followed player, Style, layer menu, and its camera-lock
  or correction message), or the current tool chip with the Clip tracks menu.
  The former tool strip and the separate player-actions row above the timeline
  are gone, giving the layer timeline that height. *Preview effect* joined the
  layer menu since the Clip tracks menu is hidden while a layer is selected.
- The source filmstrip is no longer drawn in the analysis timeline (the preview
  above already shows the frame); ruler and layer rows keep their positions.
- Tapping a layer row selects the layer without moving the playhead. The ruler
  still scrubs on drag and tap.
- Second pass (same day): the current-tool chip and the bottom Clip tracks
  button are gone; the Clip tracks menu now sits in the navigation bar in place
  of the "Analyse" title (`analysis-clip-tracks`), without the frame-step
  items (the transport has them) or the saved-player list (the Player tracks
  sheet is the list). The time ruler stays pinned above the vertically
  scrolling layer rows. The layer row no longer has a second message line: the
  camera-lock note and Correct became a single re-track icon in the row, and a
  player correction shows one "Tap or draw around the player · Cancel pick"
  row instead. Field setup applies directly (the "Lines align with the video"
  confirmation is gone) and opens with Detect field, Snap to lines and the
  status only; the method picker, overlay/loupe/settings icons, handle
  selectors and pixel nudges sit behind **Adjust by hand**.
- Third pass: **Detect field is the whole setup.** It detects on the current
  frame; unless that already gives a snapped fit it searches the clip for a
  clearer view, jumps there, places the detected landmark with its orientation
  and snaps to the paint, so most clips are Detect field → Apply. The reference
  picker and goal-side toggle stay visible above it; Snap to lines, the
  overlay/loupe/settings icons, handles and nudges live under Adjust by hand.
  "Find a clearer setup frame" and "Find marking intersections" are gone from
  the menu. Reference settings uses the standard sheet chrome. Clip tracks is
  an icon in the trailing toolbar cluster. Field overlay lines are sampled
  before projection so a touchline whose far end passes the horizon still
  draws its visible part. A selected player has Track to end (also in the
  Player tracks menu) to continue from its last confirmed frame to the clip end.
- **Backward and whole-clip player tracking.** `SelectedPlayerTracking.trackBackward`
  decodes 0.5 s chunks with fresh readers, replays each chunk's frames in
  reverse through the same per-frame identity logic in a mirrored time base
  (`t' = seed − t`), then maps samples and gaps back to source time; a loss
  going backwards simply becomes the track's start, never a terminal loss.
  `PlayerMotion.prepending` joins that in front of the existing track at the
  seed frame. A selected player's "Track more" menu offers Track whole clip
  (backward then forward from the current frame), Track back to start and Track
  to end; the Player tracks menu has Track whole clip too. A new player picked
  mid-clip is followed forward and then automatically backward to the clip
  start. Phone check: backward from 8 s to 3 s on the stress runner took 1.5 s,
  reached 3.0 s with no gaps and agreed with the forward track on 23/23 frames
  (`/tmp/roster-phone-back.xcresult`).
- **One Player bar.** The workspace no longer has separate bars for "a saved
  player picked on the video" and "a drawing that follows a player". Whenever a
  player is involved (tapped on the video, chosen from the list, or its effect
  layer selected) the bottom row is `kit swatch · name · #number | Effects |
  Tracking | ⋯`. Effects opens the player-effects sheet. **Tracking** opens one
  sheet with a coverage bar (blue tracked, orange missing, tap to jump), the
  status, *Track whole clip* / *Track to the end* / *Track back to the start*,
  gap arrows, *Fix from this frame* (re-track after tapping the right player),
  *Place on this frame by hand*, the bridge and smoothing sliders when a
  drawing is selected, and rename/remove. ⋯ holds the layer housekeeping.
  A detected body that is not a saved player shows `New player | Effects |
  Track`. Drawings that do not follow a player keep `Motion | Style | ⋯`.
  Player-tracking controls are no longer sprinkled across the bar; UI tests
  reach them through `analysis-player-tracking` first.
- **Tone cues for same-kit players.** Identity memory now also keeps a head
  (skin/hair) and a legs (socks/skin) *brightness* histogram, sampled from the
  top 13 % and the 72–94 % band of the detector box on bodies at least 6 % of
  the frame tall. In matching, a confirmed tone that clearly disagrees costs
  40 % of the score (15 % for a mild disagreement) and a strong agreement adds
  a little; unreadable tones do nothing, so short or distant bodies fall back
  to kit colour. Both the roster pass and single-player tracking use the same
  `PlayerIdentityMemory`; the single tracker carries it on the source track
  (`PlayerMotion.identity`, stripped from drawing copies) so Fix / Track whole
  clip keep what earlier passes learned. Phone check after the change: stress
  runner 25/25 with single tracking, backward 23/23, crossing test still ends
  on the blue player, 27 footage/editing/repair tests green
  (`/tmp/roster-phone-tone.xcresult`). Real evidence for two same-kit players
  with different skin tones is still needed from a clip that has them.
- **Chromaticity kit signature (the floodlight switch).** Miguel's saved stress
  project showed the blue "Player 2" jumping onto the white player crossing
  behind him at 13.07 s. Cause: the hue histogram bins low-saturation pixels as
  neutral, and under floodlights most blue-shirt pixels read that way, so blue
  and white kits scored as the same kit and the gate never fired. Identity
  memory now also keeps a torso *chromaticity* histogram (r and b shares of
  r+g+b, 5×5 soft bins), which is brightness-independent; a confirmed chroma
  that clearly disagrees cuts a candidate's score to 40 % (70 % for a mild
  disagreement), so a white body fails the kit gate for a blue player. Both
  trackers use it through the shared `PlayerObservation.observe`. Number reads
  now run on a zoomed torso crop (accurate mode, bodies ≥ 8 % of frame height)
  in both trackers; on the night stress clip none is legible, so they did not
  contribute there. Regression test `testBlueRunnerStaysBlueWhenAWhitePlayerCrossesBehindHim`
  re-tracks the same seed from 12.8 s: the track keeps the narrow blue box
  through the crossing, hides for 0.4 s while the bodies overlap, and picks the
  blue player up again; frames at 13.3 s and 13.8 s inspected. Footage, editing
  and repair suites green on MM (`/tmp/roster-phone-chroma.xcresult`,
  `/tmp/roster-phone-blue.xcresult`); roster on the stress clip: 23 players.
- **Reference gallery (feature prints).** Each player now also keeps up to
  eight Vision image feature prints of the body crop
  (`PlayerAppearanceGallery`, cosine similarity, diversity-preserving
  replacement, gate derived from the player's own least-similar pair). Both
  trackers learn a print every 0.5–1 s from clean frames; candidates near the
  prediction (single tracker) or unowned bodies (roster) get prints when the
  gallery is ready. A candidate below the gate loses 30–65 % of its score; a
  bonus needs at least six references. Prints are stored rounded on the saved
  player. Roster pass cost on the stress clip rose from about 7 s to 9–13 s.
- **Tackle case from Miguel's second tagged project.** "Player 3" went blue →
  white → blue around 9.6 s. Seeded on the blue carrier on a clean frame a
  second earlier, the track now stays on the blue player through the tackle
  and leaves with him (`testBlueBallCarrierIsNotHandedToTheWhiteDefenderInATackle`,
  frames at 9.6 s and 10.0 s inspected). Seeded *inside* the tackle it stops
  after three frames, by design: an unconfirmed seed next to another body does
  not recover unless a lone body matches every cue at ≥ 0.9. Relaxing that
  (following crowded frames while unconfirmed, or a 0.8 threshold) was tried
  and reverted because the mixed-overlap crossing test then ended on the white
  player. Per-frame chroma and box-growth checks on the optical box were also
  tried and reverted: they stopped good tracks early. `PlayerTrackingLimits.trace`
  is a diagnostic hook the footage tests use to print each tracking decision.
- **Presence rule.** A player whose last confirmed box did not touch a picture
  edge is still in the frame, so a lost player is no longer searched only near
  where he vanished. Single tracking: once dormant (missing > 2.5 s) and not
  left through an edge, every uncrowded body in the frame is compared against
  the full memory (kit, chroma, tones, number, feature-print gallery); the one
  body that matches at ≥ 0.85 and beats the runner-up by 0.1 is followed after
  three confirmations (`PlayerPresence.findAnywhere`). Roster: a dormant player
  who did not leave through an edge gets a search radius that grows from 0.3
  to the whole frame over the seconds he stays missing; edge exits keep the
  0.4 re-entry radius. Two same-kit bodies leave the player hidden. Footage,
  editing and repair suites green on MM (`/tmp/roster-phone-presence.xcresult`);
  the roster pass on the hot phone took about 20 s for 9.7 s of footage.
- **Cues combine as gates.** After a blue player was handed to a white one
  again (unsaved attempt, not reproducible from the phone), the identity score
  no longer merely shrinks on a failed cue: a confirmed kit chroma below 0.5, a
  confirmed head/legs tone below 0.4, or an embedding likeness more than 0.1
  under the gallery gate now zeroes the candidate outright. Far re-acquisition
  of a present player additionally requires a confirmed chroma, a ready gallery
  that agrees, and a trajectory-plausible position (at most about 0.12 + 0.3 ×
  seconds missing from the camera-relative last position). Footage, editing
  and repair suites green on MM (`/tmp/roster-phone-gates.xcresult`): runner
  23/23, backward 21/21, tackle and crossing cases unchanged, roster 9.5 s.
- **Distant players and roster re-identification (16 September 2026).**
  Miguel's saved project (21:41): a blue player seeded on the first frame at
  11 × 50 px was lost at 5.63 s and never recovered. Every recovery gate scaled
  with the body width (two widths = 22 px), so jitter and a small pan defeated
  it and single sightings never confirmed. Association gates and the recovery
  confirmation now use a minimum unit of 0.03 × 0.06 frame units
  (`PlayerTrackingLimits.minimumGateWidth/Height`); the same seed now tracks
  0–14 s with one 0.4 s gap through the 6 s recovery and the 9.5 s tackle
  (`testDistantBluePlayerSeededOnTheFirstFrameIsTrackedThroughRecoveryAndTackle`).
  That change exposed roster weaknesses on the stress runner, fixed in turn:
  feature prints of bodies under 8 % of the frame height are neither learned
  nor used to reject (`PlayerAppearanceGallery.minimumBodyHeight`); late
  re-identification compares the body's *current* position with the player's
  *current* expectation and bounds the distance by 0.05 + 0.2 × seconds
  missing, is mutual-best against other new bodies, and its "only player of
  this kit missing" fallback obeys the same bound (a kit that is full still
  merges the nearest); the crowd offset needs four voters at 60 % and is capped
  by the time missing. Roster traces go through `PlayerTrackingLimits.trace`.
  Phone: 30 footage/editing/repair tests green (`/tmp/roster-phone-gate14.xcresult`),
  runner 23/23 and re-acquired after an 8 s loss, backward 23/23.
- **Front crossings (merged detector boxes).** Miguel's saved project (23:08):
  the first-frame blue player was handed to a white player who ran across in
  front of him at 25.8 s. Trace: the detector returns one box for both bodies
  (height 0.085 → 0.125, width unchanged), it is not "crowded" by overlap, the
  tracker re-anchors to it and learns from it, and when the bodies part the
  optical tracker keeps the front one. Now a body that suddenly stands more
  than 1.35× the player's recent median height (`PlayerTrackingLimits.isMerged`,
  history restarted after long gaps, kept across a short loss inside a merge)
  is followed *without learning*, and the first single body that comes out of
  the merge must still score ≥ 0.75 against the full memory (kit chroma, tones,
  gallery) or the player is hidden and recovery looks for him. Rejecting merged
  boxes outright was tried first and reverted: the tackle case, where the blue
  player is the one in front, then died at 10.5 s. Same logic in the roster.
  Regression `testBluePlayerStaysBlueWhenAWhitePlayerRunsAcrossInFront`: the
  track hides for 0.3 s at 26.6 s and is back on the blue player by 26.9 s
  (frame at 27.0 s inspected). Phone: 31 footage/editing/repair tests green
  (`/tmp/roster-phone-merged4.xcresult`), runner 29/29, distant first-frame
  player and both tackle/crossing cases unchanged.
- UI tests open the Tools sheet before choosing a tool (`analysis-tools`), open
  Adjust by hand before Snap to lines, and no longer tap a confirmation before
  `ground-apply`.

## Field setup redesign: snapping to painted markings — 15 September 2026

- `PitchRegistration` refines any plane alignment (automatic proposal, traced
  lines or dragged handles) against the frame's white markings. It samples the
  whole projected pitch template, searches along each line normal for a thin
  bright stripe with dark surroundings and turf on at least one side, requires
  the paint to continue along the line direction, and solves a damped
  correction homography in template space with robust weights. The search grows
  in stages from the reference neighbourhood outwards, so a small far reference
  is locked before extrapolated lines are trusted, and one painted mark can
  support only one template line. The result reports a fit grade (good / check
  / weak), median residual in source pixels, evidence coverage and supported
  line count. These describe agreement with visible paint, not metric accuracy.
- Field setup is one flow: choose a frame, **Detect field** (on-device
  proposals are now snapped and ranked; the centre-spot circle workflow remains
  the fallback when a snapped proposal grades weak) or place a landmark / trace
  lines, then **Snap to lines**. A quality badge sits on the preview and details
  appear in Reference settings. Editing any point clears the grade until the
  next snap; Apply still requires the explicit alignment review. The mode
  switch became a method menu, nudge arrows are always visible, the loupe can be
  pinned, and dimension fields commit on every keystroke (closing settings used
  to drop the last typed value). The unreachable "Detect field lines" and "Place
  visible field" sheets were removed.
- Performance: one `FieldFrameSource` keeps the asset, image generator and
  metadata for the session instead of rebuilding them per frame step, and the
  pitch model is prepared once per process. On MM in Release a 1080p snap
  measured 5 ms for evidence and 17 ms total (`PITCH_SNAP` in
  `/tmp/field-snap-phone-2.xcresult`); the unoptimized simulator took 0.63 s.
- Synthetic verification: `PitchRegistrationTests` render a pitch from a known
  homography with band-varying line widths, noise, white shirts and a bright
  stand. From 18 px corner perturbations the whole-pitch snap lands within 1.5
  px with a good grade; a far penalty-area reference perturbed by 14 px lands
  within 1.5 px; flat turf grades weak; traced lines reproject onto the snapped
  template and refit identically. `FieldSetupUITests` seed a video made from
  that frame and pass on the iPhone 17 Pro simulator: rough whole-pitch handles
  snap to "Good fit", editing clears it, settings keep it, Apply then reopen;
  and the method menu / overlay / landscape checks. Note: the earlier result
  bundles for those simulator runs were corrupted when the Mac's disk filled;
  the passing runs are recorded in the session log only.
- Real footage (MM, Release): all 9 `FieldFrameSelectionTests` and 6
  `PitchRegistrationTests` passed (`/tmp/field-snap-phone-2.xcresult`). The
  stress clip's centre-circle proposal snaps to the circle and halfway line
  only ("Weak fit · 0.7 px · 2 lines", coverage 0.21): its far touchline is not
  visible at 1080p (grass meets a blue track), so the perspective cannot be
  confirmed by paint there and the app says so. The attached overlay was
  inspected. This is not evidence that whole-field snapping works on all
  footage; a frame with visible box or touchline paint is needed for that.
- Phone walkthroughs passed without saving the stress project:
  `testReviewableAutomaticFieldAlignmentAndFrameChoiceWithoutSaving` (detect,
  nudge, re-snap, confirm, landscape; `/tmp/field-snap-phone-2.xcresult`),
  `testLiveFieldOverlayCanBeAlignedComparedAndCancelled` and the two-point custom
  reference (`/tmp/field-snap-phone-5.xcresult`),
  `testEditorLayoutAndFieldFrameSelectionWithoutSaving`
  (`/tmp/field-snap-phone-3.xcresult`) and the four-point custom rectangle
  (`/tmp/field-snap-phone-11.xcresult`). Three of those tests carried stale
  assumptions (exact accessibility strings, no review tap, the fixed-camera
  switch read after the sheet closed) and were corrected. Portrait and
  landscape screenshots were inspected; a truncated method label found in the
  first pass was fixed before the final runs.
- The verified Release build was installed and launched on MM at 00:52 on
  15 September 2026.

## Perspective circle reference — 14 September 2026

- The circle proposal now fits a full projective conic to white marking samples
  at the original frame resolution. The coarse region model only seeds the
  search; the halfway line is also refined against source pixels. This replaces
  the affine-only circle initialization described below.
- A detected circle needs either one correction on the actual centre spot or
  two points tracing the far touchline. The touchline alternative recovers the
  centre from the two circle crossings and known pitch width; confirm the actual
  width in Reference settings, especially on non-regulation grounds. The ellipse
  centre is not assumed to be the projected field centre.
- Alignment options → Find a clearer setup frame tries at most four frames with
  one model load. It prefers a complete, refined circle and otherwise returns a
  reviewable area proposal. It is a bounded search, not a whole-clip guarantee.
- The preview updates while editing, with pinch/pan, loupe and source-pixel
  nudges. Applying requires a completed correction and explicit alignment review.
  A sharp-angle warning uses sensitivity to a one-pixel centre perturbation;
  curve residual and sensitivity are not measurement-accuracy guarantees.
- The conic, corrected centre and reference lines persist with the calibration
  and reproject through the existing shared camera track. This change does not
  add semantic camera realignment during pans or eliminate existing camera drift.
- Verification: `/tmp/circle-halfway-fixed-phone.xcresult` passed all 9
  `FieldFrameSelectionTests` and the non-saving field UI walkthrough on MM
  iPhone16 in Release. Tests cover perspective recovery, invalid constraints,
  persistence, camera reprojection, actual stress-footage detection and a bounded
  clearer-frame search (8.27 seconds cold; warm single-frame detection 0.24s).
  The full field overlay and portrait/landscape screenshots were inspected.
  That visual inspection caught an offset halfway seed; its source-pixel search
  was widened and a real-marking regression check added before the final pass.
  The fixture overlay assumes 68m width and does not establish metric accuracy.
  All field/analysis drafts were cancelled; no simulator or saved project edits.
- The verified Release build was explicitly installed and launched on MM
  iPhone16 at 19:49 on 14 September 2026; the running app process was confirmed.

## Saved-player selection, short gaps and field alignment — 14 September 2026

- A following layer exposes its player name. Tap it to choose a saved player;
  the picker marks the current track and shows source-time coverage. Rebinding
  changes only that layer, preserves its styling/timing/player-relative offset,
  and never runs tracking or modifies the source tracks. Locked layers and
  connection endpoints are excluded from this single-player operation.
- Player effects and saved-track management use native navigation bars and
  medium/large sheets. Detailed text, loupe and trajectory controls open on demand.
  Layer rows and their blue/orange coverage canvases now share the filmstrip's
  full-width coordinate space; the handle safety inset is retained in time scaling.
- Display-only interpolation bridges gaps up to 0.4 seconds when confirmed
  samples bracket the gap within 0.5 seconds, with compatible size and nearby
  positions. Offscreen bounds, large jumps, explicit correction boundaries and
  terminal losses are not bridged. Raw gaps remain orange and metric speed
  remains unavailable across them. This supersedes the older blanket statement
  that every tracking gap hides an effect; trajectory paths still split at gaps.
- Field alignment now accepts visible portions of named white lines (at least
  two distinct lines in each field direction), so their intersections may be
  offscreen. A fitted field is overlaid for review. A bundled, MIT-licensed
  Spiideo pitch-region model can propose a centre-circle/area starting alignment
  on the chosen frame; it does not automatically certify metric calibration.
  Circle initialization is affine and must be refined against perspective.
  Manual landmarks, frame stepping, pinch/pan, loupe and pixel nudges remain.
- Release phone verification: all 17 `PlayerTrackRepairTests` and
  `FieldFrameSelectionTests` passed in `/tmp/analysis-reuse-field-phone.xcresult`,
  including real stress-footage interpolation/repaired tracking, independent
  layer rebinding, partial-line fitting and model inference. The pitch proposal
  itself took 9.07 seconds on MM (first run); its image and tracked-player frames
  were inspected. UI verification is recorded separately because this run's
  UI runner timed out while enabling automation, before any walkthrough ran.
- The UI-only retry in `/tmp/analysis-reuse-ui-phone.xcresult` hit the same
  automation-initialization timeout; the new sheet/layout walkthroughs remain
  unverified, not passed. The Release app was installed and launched on MM at
  18:49 on 14 September 2026. No simulator or saved stress-project edits.

## Analysis vertical scrolling and transport — 14 September 2026

- Timeline rows, thumbnails and the ruler use a direction-selective UIKit
  recognizer. It rejects vertical movement before recognition so the enclosing
  vertical scroll view can scroll normally. Horizontal movement keeps the shared
  time axis and existing layer/keyframe edits, with a four-point threshold for
  small trims. Two-finger inspection and timeline magnification remain separate;
  disabling editing also disables the native recognizers.
- The source filmstrip has the full workspace width, sharing the same time
  coordinates as the inset layer handles. Previous/next-frame controls are back
  beside playback, using the source video's nominal frame rate.
- The initial SwiftUI-only direction guards still blocked vertical scrolling on
  MM; a physical-device test reproduced it. The native recognizer passed the
  eight-layer non-saving walkthrough in
  `/tmp/analysis-vertical-scroll-native.xcresult`: reach the oldest layer, return
  to the thumbnails, scroll vertically from a drawing or thumbnail, preserve all
  layer timing, scrub horizontally, and step forward/back by one frame. Both
  portrait screenshots were inspected. No stress-project edits were saved.
- Final Release checks: all 11 `AnalysisLayerTimelineTests` passed in
  `/tmp/analysis-scroll-final-phone.xcresult`. The UI run exposed an incorrect
  landscape test assertion against the background's safe-area extension; the
  corrected viewport assertion and explicit portrait setup passed both phone
  walkthroughs in `/tmp/analysis-scroll-reviewed-phone.xcresult`. These cover
  nine-point trimming, keyframe dragging, pinch zoom, landscape frame controls
  and the eight-layer scrolling checks. Final portrait/landscape screenshots
  inspected; both walkthroughs canceled without saving. Verified Release
  installed and launched on MM at 18:13 (process 3932); no simulator used.

## Single analysis timeline — 14 September 2026

- Removed the Timeline/Layers picker, separate layer list and its selection
  state. Drawing tracks remain directly below the source filmstrip in the same
  timeline, retaining selection, trimming, zoom and layer actions. The rest of
  the editor layout is unchanged. The physical MM Release walkthrough passed
  in `/tmp/analysis-single-timeline-phone.xcresult`, checking the absence of the
  picker, layer selection below the filmstrip, zoom and landscape handles.
  Portrait and landscape screenshots inspected; canceled without saving the
  stress project. Release installed on MM at 17:35.

## Field reference scrubbing and editor layout parity — 14 September 2026

- Field placement includes a time scrubber, one-second jumps and native-rate
  frame steps. Frame loads are cancellable/debounced; Apply and point editing are
  blocked while the displayed image does not match the requested time. Frame
  changes clear alignment confirmation and marking suggestions. A covered camera
  pass reprojects the current draft to the new frame; otherwise the editable
  points remain and must be aligned again. Apply stores the selected source time
  and returns Analyze to it. Freeze-frame placement retains its fixed source and
  independent annotation time.
- Analyze uses the main editor's native navigation styling, preview playback
  overlay, `EditorPanelSizes`/`EditorPanelDivider`, Timeline/Layers workspace and
  horizontal `EditorActionStyle` tools. Landscape puts the workspace beside the
  preview. The timeline includes cached visible source thumbnails; zoom survives
  switching between Timeline and Layers. Motion mode is a compact menu instead
  of a full-width segmented row.
- Physical MM Release checks: `/tmp/analysis-frame-layout-check.xcresult`,
  18 passed (field-time rebasing, missing-camera behavior, freeze timing,
  field preview and annotation timeline). The non-saving phone walkthrough in
  `/tmp/analysis-layout-field-phone-final.xcresult` passed time stepping,
  later-frame selection/reopening, workspace resizing, drawing, layer selection,
  zoom retention and landscape playback access. Screenshot review identified
  unsupported one-second symbols and a crowded landscape layer row: jumps now
  use explicit −1s/+1s labels, short workspaces use smaller source thumbnails,
  and redundant vertical padding was removed from layer controls. The final
  `/tmp/analysis-layout-reviewed-phone.xcresult` walkthrough passed, including
  full landscape handle visibility. Portrait, landscape and field-time
  screenshots were inspected. All walkthroughs canceled without saving the
  stress project. The field draft is deliberately unaligned; this is not
  evidence of measurement accuracy. The verified Release was installed and
  launched on MM at 17:14; no simulator was used.

## Shared clip camera, stable player arrow and editor styling — 14 September 2026

- Field setup and camera-following layers use one clip-owned camera job. Its
  range covers the whole clip, plus any saved geometry reference outside a trim.
  Changing the field reference or adding another effect reuses that pass.
  Legacy field-only/annotation camera snapshots are promoted and rebound to the
  shared source while retaining their authored reference frames. A shorter
  failed retry does not replace a longer usable pass. Cuts/loss still hide
  unsupported geometry rather than claiming coverage.
- Field previews use the same sample-boundary rules as camera-following layers.
  The last decoded frame is included even off the normal sampling cadence; its
  transform holds through the final display interval, including a sub-frame
  video/audio duration difference.
- Player arrows use a centred 0.8-second complete-body height average, separate
  from tracking position and ring contact. Missing sections, explicit correction
  boundaries and cropped boxes do not contaminate that average. Grounded and
  ungrounded arrows use the same geometry; decorative vertical bobbing is removed.
- Analyze and the main editor share timeline zoom controls and ruler intervals.
  Analyze now matches the editor's layer opacity, white selected outline,
  playhead cap and inline name/duration. Header actions are unboxed and playback
  time uses the editor typography. Preview effect remains in the clip menu.
- Physical MM Release checks: `/tmp/unified-analysis-final.xcresult`, 26 passed
  (shared-camera migration/rebinding/coverage, marker stability and actual-footage
  export, field preview and layer timeline). The complete 33-second stress clip
  produced 497 samples including both endpoints, no loss, in 2.91 seconds.
  Exported marker frames at 3 and 5 seconds and draft field overlays at 0 and
  32.97 seconds were inspected. The test plane is intentionally approximate;
  this does not validate metric field calibration.
- Phone UI: compact header/loupe-inspector walkthrough passed in
  `/tmp/unified-analysis-ui.xcresult` (workspace screenshot inspected). Shared
  full-clip camera → later field reference → available preview passed in
  `/tmp/unified-analysis-ui-verified.xcresult` (screenshot inspected). The initial
  camera UI test tapped a menu command while trying to dismiss the menu; its
  corrected outside-menu tap passed. Successful walkthroughs canceled without
  saving the user's project. Release installed on MM at 16:18 and launched at
  16:19 (process 3133).

## Camera pass performance and pixel placement — 14 September 2026

- Camera registration now prepares each decoded grayscale image once and lazily
  reuses the anchor's corner descriptors. Translation/projective proposals and
  adjacent-frame fallbacks share those prepared images. The cache belongs to one
  pass and retains only the current, previous and anchor frames; it does not
  replace or invalidate saved tracks. Sampling, search radii, consensus trials
  and rejection thresholds are unchanged.
- Physical MM benchmark `/tmp/camera-speed-release.xcresult`: 29.9 seconds of the
  stress recording processed in **2.34 seconds**, 449 samples, no lost track.
  Eight camera/ground-geometry checks passed; six measured landmark errors were
  0.26–2.94 pixels at 1080p. Real footage frames at 3, 9 and 32.8 seconds were
  visually inspected. The earlier installed Debug build took about 90 seconds
  for this pass. This comparison includes both caching and compiler optimization;
  it is not a claim of a 38× algorithm-only improvement or a guarantee for all
  footage. Use optimized Release builds for device performance evaluation.
- Hosted-test recovery/sync suppression also applies to Release unit tests;
  normal app launches retain normal recovery and sync behavior.
- Field placement offers four 44-point arrow buttons for the selected landmark.
  Each tap moves one original, oriented video pixel, including 4K sources whose
  inspection frame is downsampled. Preview zoom/pan does not alter the step and
  offscreen landmarks are not clamped to the image edge. Nudging keeps a loupe
  visible, clears alignment confirmation, and does not start camera processing;
  calibration remains a draft until Apply. Landscape controls can scroll.
- `/tmp/field-pixel-nudge-phone.xcresult`: all seven placement/gesture geometry
  tests passed on MM, including source-pixel steps at 1080p/4K, portrait axes,
  offscreen coordinates and inverse nudges. Its UI runner and the retry at
  `/tmp/field-pixel-nudge-phone-retry.xcresult` timed out enabling automation
  before any taps. A final connected-device attempt stalled before runner launch
  and was interrupted. The new nudge UI is **not yet visually/touch verified**.
- The optimized Release app was installed at 15:39 and launched at 15:40 on MM.
  No simulator, fixture reset, recording overwrite or saved stress-project edits.

## Per-point field-plane geometry — 14 September 2026

- Grounded rectangles expand their two diagonal controls into four metric-plane
  corners, and grounded ellipses project 96 perimeter samples. They no longer
  rebuild screen-aligned bounding boxes after camera motion. Wall and aerial
  bases use those same corners. Legacy two-control polygons project their
  implicit third corner on the field as well.
- Circle, arrow and freehand layers now offer Ground to field. Grounded arrow
  heads and circle/point endpoints are drawn on the plane. Stroke widths and dash
  lengths remain screen-space styling for readability, not metric dimensions.
- Selection bounds and all four rectangle/ellipse resize handles use projected
  geometry. Grounded shape translation preserves metric dimensions; vertex
  resizing maps the touched corner back through the plane. Authored image
  coordinates, keyframes and player tracks keep their existing storage contract;
  no duplicate geometry cache or destructive tracking migration is introduced.
  Enabling grounding reuses the shared camera pass for static drawings, while
  existing player/keyframe motion remains explicit. Rectangles and ellipse axes
  align with the calibrated field axes. Calibration quality still determines
  alignment; a two-point local scale cannot define this plane.
- `/tmp/ground-shape-plane.xcresult`: twelve tests passed on physical MM,
  including all projected corners/curve samples, four-handle resize round trips,
  field-space translation, projective camera movement for six tools, Codable,
  keyframe retention, missing camera coverage, clipped-player regression and
  existing wall/roof preview/export. No simulator or stress-project saves.
- `/tmp/ground-shape-phone-ui.xcresult` passed the expanded rectangle, ellipse,
  grounded dashed arrow, wall and aerial preview/export test on real footage;
  both rendered images were inspected. Its UI runner timed out enabling iOS
  automation. `/tmp/ground-shape-phone-ui-retry.xcresult` then passed the physical
  phone walkthrough: enable grounding, inspect all four projected handles,
  resize a corner, verify grounding remains enabled, Cancel without saving.
  Before/after screenshots confirm the opposite corner stays fixed and the
  rectangle follows the deliberately approximate draft field axes.
- Verified build installed and launched on MM at 15:24 on 14 September 2026.

## Scene-feature camera tracking and field preview — 14 September 2026

- The editing camera pass now fits a projective transform to spatially distributed
  textured image matches. Normalized patches reduce exposure sensitivity;
  ambiguous matches, failed backward checks, moving outliers and degenerate
  support are rejected. Vision translation is a search initializer, with a
  separately verified homographic proposal for larger zoom/roll. A plausible
  Vision matrix alone is not accepted. The lightweight player-recovery camera
  helper is unchanged, avoiding changes to saved player identity behavior.
- Short reference frames still limit incremental drift. Camera tracks are reused
  across drawings, ground measurements and effects; existing saved tracks are
  not automatically overwritten. Re-track to use the new estimator. This is
  offline image-plane compensation, not real-time SLAM, lens calibration or a
  guarantee against parallax, blur, cuts or foreground-dominated scenes.
- **Field** in Analysis tools toggles a preview-only guide during scrubbing and
  playback. With no calibration it opens Measure. Saved pitch references show
  cyan field lines and a white reference; custom/local references show their
  reference geometry. Inspection zoom/pan shares the video coordinate frame.
  Missing camera coverage hides stale lines and shows a warning within the
  visible preview. No drawing layer is inserted and export is unaffected.
- Physical MM evidence: `/tmp/camera-precision-baseline.xcresult` reproduced the
  old zoom/roll failure. `/tmp/camera-precision-final.xcresult` passed ten focused
  camera/shared-render checks: combined 5.5% zoom/2° roll under 0.5 pixels at 640px,
  identical-frame identity, outlier/degenerate rejection, flat grass/cut rejection,
  player-recovery direction regression, shared preview/export, and a camera pass
  from 3 to 32.9 seconds with 449 samples and no loss. Six hand-read landmark
  checks at 9/13.8s had 0.26–2.94px error at 1080p; these are targeted fixture
  measurements, not whole-frame or all-scene accuracy. Later frames at 18, 23,
  28 and 32.8s were visually inspected. The debug phone pass took about 90s for
  29.9s of footage (the earlier 11s benchmark took 28s), so do not call it realtime.
- `/tmp/camera-field-preview-ui2.xcresult` passed the four field-preview geometry
  checks and a non-saving phone walkthrough: open field setup, show the overlay,
  scrub, toggle off/on, Cancel. The deliberately unaligned draft fixture makes
  overlay mismatch visible; it is not an automatic-calibration accuracy claim.
  Its screenshot was inspected. That run also exposed a wall test attempting to
  operate an offscreen height slider; the test now scrolls it into view first.
- The extra wall-control retry (`/tmp/camera-grounded-wall-ui.xcresult`) was
  interrupted while the phone's InCallService repeatedly blocked automation;
  it is not a passing wall-control result. The camera/Field preview checks above
  passed separately. Latest build installed and launched on MM at 15:10
  Europe/Madrid. Tests used draft edits and Cancel, without saving changes to
  the stress project. No simulator was used.

## Perspective walls and crop-safe player effects — 14 September 2026

- Drawing style includes **Ground to field** for players, spotlights, areas,
  rectangles, lines and connections. It requires a four-point plane in Measure;
  a two-point local scale cannot define 3-D perspective. Wall/aerial height is
  editable in estimated meters when grounded. Existing walls retain their old
  screen-space appearance until grounding is enabled.
- Wall tops and aerial roofs use the ground homography's metric axes and plane
  normal, so near/far height and camera roll affect the extrusion. Intrinsics
  assume square pixels and a centred principal point, with a bounded focal
  estimate: this is an approximate pinhole model, not recovered lens metadata
  or automatic scene reconstruction. The mathematical basis is the
  [homography pose decomposition](https://docs.opencv.org/4.13.0/d9/dab/tutorial_homography.html);
  no OpenCV dependency is added. Shared camera motion warps both base and top,
  avoiding per-frame focal estimation. This does not model true off-plane
  parallax or occlude virtual walls behind players.
- Enabling grounding on a static unkeyed drawing attaches the existing field
  camera pass at its current pose. Player-linked/keyed drawings keep authored
  motion. Grounded effects hide when the field has no camera coverage instead
  of showing a stale plane. Preview and export share the same projection.
- Player effects use full-body proportions independently from tracking boxes.
  Recent complete observations estimate body extent when boots/body are cropped
  at the image boundary. Feet can remain outside the image; the halo is clipped,
  not shrunk and pinned to the crop edge. No inference crosses tracking gaps or
  manual correction anchors. Raw saved tracking remains untouched.
- Current verification: physical MM passed eight focused grounded-effect tests
  plus the real player-follow/preview/export test in
  `/tmp/grounded-effects-final.xcresult`. Ten repair regressions passed in
  `/tmp/grounded-effects-phone.xcresult`; that earlier run also contained a stale
  raw-box ring-pixel expectation, corrected and passed in the final run above.
  Preview/export and cropped-player image attachments were visually inspected.
  UI walkthrough is incomplete: the first attempt timed out enabling automation;
  the next needed a corrected toggle hit target and inspector scroll. Before the
  corrected retry, MM disconnected (`unavailable` in CoreDevice, no Xcode device
  destination). No final installation/launch confirmation or passing UI claim;
  reconnect MM to finish. No simulator or saved project fixture edits used.

## Non-destructive player repairs and grounded indicators — 14 September 2026

- Player corrections splice only the newly confirmed section into saved motion.
  Earlier/later samples, gaps, identities and effect bind poses survive. Explicit
  correction times are persisted; an earlier repair cannot overwrite the next
  manual correction. Sustained agreement can rejoin the existing track early.
  Smoothing respects those boundaries and leaves the explicit correction exact.
  Cancelled/failed processing does not replace a saved track with a placeholder.
  Connection failures focus the failed pass, even when preserved future coverage
  means the merged track no longer has a terminal loss.
- Missed small players receive a local higher-resolution detector crop, using
  the existing Hoops sports model and the same jersey/ambiguity gates. Recovery
  registers the upper background instead of trusting a full-frame grass warp.
  Player velocity is measured after aligning the same two frames, avoiding false
  movement caused by subtracting camera velocities from mismatched time windows.
  Sparse searches continue after the 2.5-second prediction horizon, with stricter
  appearance and three-observation confirmation. Predicted positions remain
  hidden and are never saved as confirmed tracking.
- Halos, spotlights and connection endpoints share a stabilized foot-contact
  estimate. A local motion fit and bounded lower-foot envelope reduce stride/box
  jitter without smoothing across gaps or correction anchors. Existing ground
  calibration still supplies perspective projection when available; without it,
  this is an image-space contact estimate, not automatic 3-D pitch reconstruction.
- Physical iPhone MM verification (no simulator): repair splicing/Codable,
  later-anchor protection, failed repairs, shared-effect isolation, ground contact,
  jersey ambiguity, dormant confirmation, real crossings and preview/export passed.
  On two distant players in the stress recording, the old tracks ended near 9.4s;
  both now recover after the pan and reach 14s with independently checked source
  positions. Hidden intervals remain about 0.43s/0.70s for the first player and
  2.17s for the defender leaving the view. This is targeted footage evidence, not
  a claim that arbitrary occlusions or identical jerseys are solved.
  Evidence: `/tmp/player-repair-final.xcresult`,
  `/tmp/player-repair-crossings.xcresult` and `/tmp/player-repair-anchored.xcresult`.
  The final correction walkthrough uses the gesture surface's real bounds (not
  the accessibility container's union of hint/preview children), and screenshots
  confirm the same runner before/after correction. Fifty distinct focused checks
  passed across these runs. Phone walkthroughs use draft edits and
  Cancel; the existing stress project and recording are not overwritten.
  Verified build installed and launched on MM at 13:52 Europe/Madrid.

## Live field alignment and resilient connections — 14 September 2026

- Measure now opens a live projected pitch overlay, with the chosen reference
  highlighted and related markings visible in white. Penalty/goal areas, half
  pitch, whole pitch and centre circle have four numbered anchors matching a
  small reference diagram. Moving a handle updates the complete overlay.
- Centre-circle alignment uses two halfway-line intersections and two endpoints
  of its perpendicular diameter, not the extrema of the image ellipse. Its four
  anchors are converted to metric rectangle corners. Saved semantic metadata
  restores the same template and editable anchors when reopened. Legacy metric
  references without metadata remain Custom; old local scales are not silently
  promoted to a plane.
- Pinch/two-finger pan, an offset placement loupe, off-image placement, a compare
  toggle and an explicit alignment confirmation support manual checking. Reference
  and pitch dimensions are editable in settings (105 × 68 m defaults are not an
  automatic measurement). Optional image detection suggests intersections only;
  it does not claim a calibrated pitch or replace the user's reference points.
- Connection rendering uses only confirmed player positions, reconnecting the
  survivors in their original order while at least two remain. A recovered player
  reappears at its original endpoint. Distance labels use the same surviving
  geometry. Polygon areas still require all tracked vertices to avoid inventing
  a different region. Original endpoint arrays and reusable identities are retained.
- Selected connections expose numbered, 44-point player cards with tracking status
  and direct correction. A failed pass seeks the last confirmed frame and opens
  the relevant player's reference card; successful tracks remain reusable.
- Analysis timeline names are inside the clips, removing the fixed name column.
  Playback controls use smaller unboxed icons with 44-point touch targets.
- Verification on physical iPhone **MM** (no simulator): template projection and
  Codable/reopening, partial connection loss/recovery, survivor distance labels,
  independent track correction, ground metric math and placement gestures passed.
  Non-saving stress-project walkthroughs covered live handles, pinch rollback,
  compare, template/settings changes, full-row alignment confirmation, timeline
  gestures and direct numbered correction cards. A real-footage check tracked two
  players independently while injecting a controlled third-endpoint gap; rendered
  frames were inspected. This tests gap behavior, not improved detector accuracy.
  Field dimensions/alignment still require manual verification; no automatic
  metric calibration is claimed.
  Evidence: `/tmp/field-live-phone{,2,3,4,5}.xcresult`; the two initial alignment
  test failures were resolved (use an actual corner drag; make confirmation's
  whole row tappable) and rerun successfully. Final correction UI passed in
  `field-live-phone5`, with screenshots inspected. Verified app installed on MM
  at 13:14 Europe/Madrid; stress-project walkthrough edits were discarded.

## Tactical effects and compact analysis workspace — 14 September 2026

- Measure offers editable full-size football presets for penalty area, goal area,
  centre-circle diameter and goal width. Area corners define a ground rectangle;
  centre-circle diameter and the bases of the goalposts provide only local scale.
  The vertical goal face is never treated as the floor. Generic automatic rectangle
  suggestions clear preset dimensions: detection does not establish real metres.
- Loupe is a timed circular magnifier, independent from full-frame Zoom. Its
  magnification, diameter and offset are editable. Player effects can attach it to
  the same saved player motion as a halo, spotlight or label, without reprocessing.
  It follows smoothed body translation without changing diameter as detector boxes
  fluctuate, and disappears across missing tracking coverage.
- All loupes sample the unannotated source, not each other or earlier drawings.
  Preview and export preserve layer order and opacity. Preview shares one oriented
  video-output frame between lenses, rejects stale frames after seeking, and bounds
  its cached image to 1280 pixels on the longest side.
- Lines support solid/dashed/dotted patterns and independent none/arrow/circle/point
  endpoints. Explicit patterns have transparent gaps; older saved arrows and
  connections retain their defaults. Polygon/rectangle Aerial adds a translucent
  ground area and raised curved, animated boundaries. Its height is a visual effect,
  not recovered metric 3D geometry; saved camera tracking can anchor its footprint.
- Compact custom headers replace oversized navigation controls, keeping 44-point
  touch targets. Style prioritises tool controls over general appearance and
  measurements; Timing and Layer remain separate tabs.
- Analysis uses a fixed centre playhead. Dragging the ruler or empty timeline left
  advances the clip; layer trims, moves and keyframes remain direct edits. Two fingers
  zoom the time axis. The preview uses one finger to draw/select and two to pinch/pan
  from 0.25× to 8×. Adding a second finger cancels the provisional drawing; lifting
  one navigation finger cannot accidentally draw. Fit appears only when needed.

Verification: `/tmp/analysis-final-phone.xcresult` contains **35 passed, zero failed
or skipped**, on MM / iPhone 16 (iOS 26.6.1), with no simulator. Three non-saving
UI walkthroughs cover compact loupe controls, polygon Aerial, dashed endpoints,
landmark dimensions, fixed-playhead forward/back scrubbing, preview pinch without
accidental marks, drawing after pinch, In trimming under the playhead and time-axis
pinch without changing layer timing. Generic drawing prompts were removed.
The 32 model/integration checks include actual selected-player tracking at 3–5.2s
with shared halo/loupe motion, source-image preview and encoded-export captures,
line gap pixels, fading, serialization, ground presets, authored zoom plus inspection
anchor math, touch cancellation and existing layer/keyframe editing regressions.
Phone workspace and actual tracked-player loupe captures were visually inspected.
The actual tracking fixture is short; this does not establish long-occlusion accuracy
or a real-time frame-rate guarantee. Two-finger pan geometry/state are unit tested;
the automated physical gesture walkthrough exercises pinch and Fit.

The verified build was installed and launched on MM at 12:41 on 14 September 2026.
User recordings and stress-project edits were not saved or replaced. The maintained
older UI scripts also compile against the fixed-centre ruler; their full suite was
not rerun in this pass.

## Ground measurements instead of field placement — 14 September 2026

- The analysis toolbar now opens **Measure**, not pitch placement. Calibration is
  shared clip data, never an extra drawing layer. Existing saved field drawings
  remain readable. Two points plus a known distance give local, approximate scale;
  four clockwise corners of a real rectangle plus both dimensions give a metric
  ground-plane homography. Neither workflow requires the whole field in view.
- The reference editor retains pinch/pan below 1×, draggable numbered points, and
  a finger-offset magnifier. Automatic reference search proposes a closed visible
  quadrilateral only when marking geometry is unambiguous; partial intersections
  are hints. The user must confirm that the shape is a real ground rectangle and
  provide dimensions. This is not semantic field recognition or automatic scale.
- Labels can show player speed in km/h; lines, arrows, player connections and
  polygons can show segment distances in metres. Local scale has an approximate
  prefix. Speed uses source-time smoothed feet over a bounded window and compensates
  for the shared camera warp. Missing calibration, gaps, or invalid camera coverage
  produce an em dash, never a fabricated zero.
- Four-point calibration projects player footprints onto the ground in preview
  and export. Other effects fall back to their existing appearance when ground
  projection is unavailable. Measurements are estimates: known dimensions, accurate
  point placement, a planar surface and a trustworthy camera warp are required.
- Moving-camera coverage starts at the reference frame and is reused by different
  measurements/effects. After a cut or failed registration, Clip tracks offers
  **New ground reference here**, replacing the clip reference. Fixed-camera mode
  must only be used for an actually stationary camera. Earlier frames without
  camera coverage remain unmeasured.
- Player recovery now retains confirmed trajectory as a search hint for up to
  2.5 seconds. Jersey, ambiguity and two-observation confirmation gates are
  unchanged; predictions remain hidden and are never saved as observed positions.

Physical-device verification on MM / iPhone 16 (iOS 26.6.1):

- `/tmp/ground-phone-verified.xcresult`: 21 passed, zero skipped, including
  non-saving two-point calibration/no-drawing-layer and four-point reopen,
  pinch/corner-drag UI walkthroughs. The phone editor screenshot was inspected.
- `/tmp/ground-phone-render-final.xcresult`: 20 passed, zero skipped, after
  bounding footprint projection work. Covers horizon branches, camera coverage,
  fixed-frame calibration reuse, camera-pan speed cancellation, gaps, serialization,
  shared references, detection geometry and actual-footage preview/encoded export.
  Exported speed/distance labels were visually inspected. Synthetic dimensions
  and motion in this render fixture test integration, not real-world accuracy.
- The actual nighttime frame at 5 seconds returned one marking intersection and
  no complete rectangle. Manual points/dimensions remain necessary on that frame;
  the detector did not fabricate a field.
- The unchanged recovery implementation's 11 identity tests and actual 3–12.7s
  crossing test passed in `/tmp/ground-phone-first.xcresult`: two recoveries, no
  final loss, correct identity/feet at 5, 9 and 12.6 seconds. All three renders
  were inspected. That initial run also exposed a test expectation about camera
  reference preservation, corrected before the passing runs above. Extended
  bleacher occlusion is not separately validated by this footage.

No simulator was used. User recordings and project changes were not saved or
replaced. Temporary verification exports were removed after checking them.
The verified build was installed and launched on MM at 11:59 on 14 September 2026.

## Hybrid jersey and trajectory tracking — 14 September 2026

- Selected-player tracking combines the existing sports detector and per-frame
  Vision tracker with a compact torso-color histogram and recent confirmed feet
  trajectories. The descriptor retains multiple colors/stripes, neutral kits and
  green jerseys. Its eight-example gallery preserves the original identity anchor
  and learns only from clear, compatible detector observations.
- A seed is provisional until another clear frame confirms its jersey. Starting
  inside an ambiguous overlap can therefore stop safely; Correct can replace that
  provisional profile. Confirmed profiles persist with the independent saved player
  track and are reused by corrections, labels, halos, connections and trajectories.
  Legacy tracks without profiles remain readable and learn one when processed again.
- Short losses allow up to 1.5 seconds of hidden recovery. Candidates must agree
  with jersey, position/size and recent movement, then pass two detector observations.
  Camera-relative confirmation avoids rejecting the same player during a pan.
  Clearly contrasting visible jerseys can separate overlapping opponents; unreadable
  or same-kit overlaps remain conservative. Predicted positions are never saved as
  confirmed samples or drawn across gaps, and trajectory history resets after gaps.
- Detector re-anchors now prime Vision on the detector's **same source frame**;
  delaying initialization until the next frame sampled the wrong region during fast
  pans. Recovery can subtract recent camera velocity from player trajectory before
  projecting into the current frame. No additional model or dependency was added.

Verification: **32 tests passed, zero skipped, on MM / iPhone 16**, iOS 26.6.1,
in `/tmp/hybrid-phone-final.xcresult` (log `/tmp/hybrid-phone-final.log`). Actual
stress footage from 3–12.7 seconds followed the blue player through two recoveries,
with manually checked identity/feet at 5, 9 and 12.6 seconds. Starting in the mixed
6.6-second overlap stopped at 6.897 seconds instead of switching identity. Checks
also cover moving-player preview/export, independent shared effects, smooth labels,
camera landmarks, trajectory gaps, legacy/profile serialization, and 192 reseeds.
The final crossing renders at 9 and 12.6 seconds were visually inspected. These are
fixture results, not a general accuracy percentage or a real-time guarantee.

The tested build was installed and launched on the phone. Stress recordings and
project edits were not saved or replaced; test exports were temporary. Existing
baked tracks are not automatically reprocessed: use Correct/retrack to apply the
new pipeline. Long absences, identical jerseys and fully hidden bodies can still
require manual correction.

## Field placement: multitouch precision — 14 September 2026

- The placement image now supports simultaneous two-finger pan and pinch from
  **0.25× to 8×**, anchored under the moving fingers. Fit resets zoom and pan only;
  corners remain source-normalized and inspection never changes exported geometry.
  Panning is available below 1× too, including for off-image reference corners.
- One finger places or drags a corner. Touching near an existing handle preserves
  the grab offset, avoiding a jump. A second finger cancels that tentative corner
  edit and starts navigation; lifting only one navigation finger cannot create or
  move a corner. Cancellation restores the pre-touch points and active selection.
- While holding or dragging, a floating crosshair loupe follows the actual corner
  and sits at least 40 points away from the finger where space permits. It moves
  below or beside the finger near edges, stays inside the preview, and magnifies
  at least 2× relative to an already zoomed image. The docked crop/nudge buttons
  remain available after release. Both magnifiers are display-only: oversized
  cropped images cannot intercept touches elsewhere on the preview.
- The SwiftUI view owns draft/viewport state; a small UIKit multitouch surface
  reports actual touch counts into a tested state machine. There is no persistence
  schema change or dependency addition.

Verification: five coordinate/gesture-state/loupe-edge checks passed in
`/tmp/field-gestures-sim.xcresult`. The completed pinch/zoomed-drag/Fit walkthrough
passed in `/tmp/field-gestures-ui3.xcresult`; `/tmp/field-gestures-fixed.mov` was
visually inspected during a held drag. It caught the docked crop's out-of-bounds
hit testing, fixed before the passing walkthrough. Two-finger pan math and
one-to-two-to-one finger transitions are covered by the model checks. Device
build: `/tmp/field-gestures-installable-build.log`. This gesture revision has not
been installed or physically tested yet; awaiting confirmation that the user's
open phone edits are saved/cancelled. Simulator walkthroughs discard their edits.

## Trajectories and mobile control targets — 14 September 2026

- **Player effects → Trajectory** adds an independently timed layer using the
  selected player's existing track. Past is solid in the layer color; confirmed
  future movement is dashed with an arrow and its own color. Each duration is
  adjustable from 0–10 seconds (0 hides that direction). This is recorded motion,
  not prediction. Paths never join tracking gaps or extend past saved samples.
- Shared camera motion is reused when available, projecting historical/future
  feet into the current view. Without camera coverage, the inspector explicitly
  identifies an image-space trail. Camera tracking/reuse on a trajectory keeps
  its player attachment; it does not replace player motion with camera motion.
  Corrections propagate from the saved player/camera tracks to their trails.
  Freeze-frame Player options do not offer trajectories yet.
- Layer options, clip tracks, correction/resume, Player effects, frame transport,
  and timeline zoom controls now use visible, full-surface 44-point-minimum touch
  targets. Motion choices use equally sized 44-point buttons with a clear selected
  state, instead of compact segmented controls. Timecodes stack to keep frame and
  effect-preview controls accessible on narrow phones. Field-placement numbers
  and nudge buttons also accept taps across their entire visible surfaces.
- The shared annotation renderer drives both preview and export, including
  trajectories. Work per path is bounded to 120 intervals, with existing player
  smoothing applied. This does not improve long-gap automatic re-identification
  or introduce metric pitch calibration.

Verification for this revision (separate from earlier device runs below):

- 20 distinct model/render/regression checks passed in the simulator: 3 partial
  field/tracker-lifecycle checks, 12 shared-tracking checks, and 5 trajectory checks.
  Results: `/tmp/analysis-trail-controls-sim.xcresult` (model suites passed; its
  first UI assertion exposed floating-point rounding of a 44-point frame), and
  `/tmp/analysis-trail-render-tests.xcresult` (all 5 trajectory checks passed).
- The corrected mobile walkthrough passed in
  `/tmp/analysis-trail-controls-final-ui.xcresult`: edge taps on clip/layer menus
  and correction buttons, minimum touch sizes, partial-field placement, nudging,
  and the layer inspector. Screenshots in
  `/tmp/analysis-trail-controls-final-ui-evidence` were visually checked; this
  caught and fixed a blank magnifier caused by its oversized image affecting layout.
- The final walkthrough also checks that playback/timecode updates survive
  returning from full-screen field placement; it passed in
  `/tmp/analysis-trail-controls-playback-ui2.xcresult`. The workspace retains its
  time observer while covered by placement. All walkthrough edits were cancelled.
- Device-target build passed (`/tmp/analysis-trail-controls-ready2-build.log`).
  **This revision has not been installed or tested on the physical phone.**
  Waiting for confirmation that the user's open edits are saved/cancelled before
  relaunching it. The isolated simulator contains an identical stress-video copy,
  but its Vision/CoreML runtime cannot create the player model inference context;
  real-footage tracking and connection correction still require device verification.

## Partial-field placement and connection correction — 14 September 2026

- **Manual field placement** opens a dedicated, full-screen placement editor;
  it no longer immediately inserts an arbitrary whole-pitch trapezoid. Choose
  **Penalty area** (default), **Half pitch**, or **Whole pitch**, and choose the
  goal side. The reference diagram identifies four corners of that visible area.
  Tap those points on the paused source frame, select/drag a numbered point to
  refine it, or use the magnified crop and one-image-pixel nudge buttons.
- The result is one field-guide layer. Its four handles belong to the chosen
  local reference, not to an unseen pitch perimeter. Rendering is confined to
  that reference; partial layouts do not extrapolate the unseen opposite half.
  **Align visible field** reopens an existing guide and preserves its timing and
  camera/keyframe attachment. Apply commits one undo step; Cancel changes nothing.
  Changing the reference clears the editor's draft points to require an explicit
  new match. Fit and 0.5×/0.25× remain available for off-image corners.
- `fieldLayout` is optional Codable metadata. Old guides without it retain their
  original whole-pitch rendering. Layout is shared by preview/export. These are
  still visual templates, not calibrated distance/speed/offside measurements.
- Fixed the Vision tracker lifecycle: supplying a newly created detector
  observation to `inputObservation` starts another tracker, rather than updating
  the existing identity. Previously this happened repeatedly within one handler,
  eventually exhausting its tracker pool. `VisionPlayerTracker` now processes a
  final request before reseeding into a fresh sequence, and closes on EOF, loss,
  cancellation and thrown errors. Ordinary frames keep using returned Vision
  observations. See Apple's [inputObservation documentation](https://developer.apple.com/documentation/vision/vntrackingrequest/inputobservation)
  and [isLastFrame lifecycle](https://developer.apple.com/documentation/vision/vntrackingrequest/islastframe).
- Selected connections/player polygons show numbered endpoint badges matching
  the **Correct** menu. Menu entries include saved player names. The failed/chosen
  endpoint is orange; a missing position is dashed and explicitly **LAST SEEN**.
  Correction shows that player's reference thumbnail and time, with a button to
  jump to the last confirmed frame. These identity aids are editor-only and never
  make missing connection geometry visible in export.

## Field detection, light walls and re-entry — 14 September 2026

- **Field / Clip tracks → Detect field lines** now reads the paused source frame
  and runs an on-device straight-marking detector. It uses turf/marking contrast,
  Hough support and overlapping-segment suppression; it does not insert a generic
  pitch. A review sheet numbers candidates and lets the user exclude false matches.
  Only accepted segments become ordinary, independently editable line layers, in
  one undo operation. Existing camera motion is reused when available at that time.
  Closing the review without accepting leaves the clip unchanged.
- **Manual field placement** remains an explicitly separate visual template.
  It starts at **0.5×** preview scale. The minus magnifier reaches **0.25×** and Fit
  restores 1×; inspection never changes exported framing. Field corners can be
  dragged beyond the source image and remain editable there. Other tools retain
  their normal source bounds. The grey surround makes the video boundary visible.
- Detection is experimental and finds straight white markings on green turf,
  not every boundary, circle, pitch type or camera view. Poor illumination,
  occlusion and background objects can cause misses or false candidates. Review
  is mandatory. **Neither detected segments nor the manual template provide
  metric calibration.** Offside analysis, player distances and speeds remain
  unimplemented: they need identified pitch landmarks, verified field dimensions
  and a time-consistent image-to-ground mapping. Feet must be used as ground
  anchors, not player-box centres; camera/lens error and track uncertainty matter.
  The separation between marking detection and calibration follows
  [SoccerNet's field-localization task](https://www.soccer-net.org/tasks/field-localization).
- **Drawing style → Wall** is available for polygons, player connections and
  straight lines. Height and light intensity are adjustable. Light rises from
  the evaluated boundary and follows its existing player/camera/keyframe motion;
  preview and export share the renderer and source-time animation. This is a
  screen-space graphic, not a physically calibrated 3D extrusion.
- During polygon/connection construction every point has a numbered marker;
  the first is lime with a **START** badge, including before a segment exists.
  These aids are editor-only and never appear in export.
- Player labels and independent text now support left/centre/right alignment,
  size, regular/bold weight and an optional background. The Player panel keeps
  these in its draft until Apply. The text inspector uses the same controls and
  layout metrics as rendering/hit-testing. Legacy text preserves its default
  font size/alignment until edited; formatting does not retrack the player.
- Tracking loss seeks to the last confirmed sample so correction is immediate.
  A saved player that is absent at the playhead offers **Resume here**: scrub to
  the return and select the same player. Earlier history and player identity are
  preserved; all attached effects stay hidden over the gap and resume together.
  This does **not** claim automatic identity recovery after a long off-screen
  absence. Jersey colour alone cannot safely distinguish returning teammates.

Verification: `/tmp/analysis-field-walls-final.xcresult` passed **29 tests**, zero
failures/skips, on the physical **MM / iPhone 16 / iOS 26.6.1**. This includes 26
model/geometry/footage checks and three non-saving UI walkthroughs for field
review/off-screen placement, connected/polygon walls, and independent reusable
player effects/text/re-entry. Actual stress-frame line detection took about
0.17 seconds in that device run (not an end-to-end latency guarantee). Screenshots
were inspected in `/tmp/analysis-field-walls-final-evidence`; the saved stress
project was not changed. Earlier duplicate-detection and ambiguous test-selector
failures were corrected before this passing run.
The verified Debug-iphoneos build was explicitly installed and launched on MM at
03:36 CEST; installation container `97C36178-D2A2-4865-873C-175170F2911D`.

## Independent players and one Player panel — 14 September 2026

- **Clip tracks → Track new player** saves source motion without creating an
  effect. Repeat for Player 1, Player 2, etc. **Manage player tracks** lists names,
  coverage and loss status, and offers rename, Use track and Correct. Processing
  runs from the selected frame toward the clip end, not backwards. Each track
  keeps its own identity and confirmed history; correction preserves explicit
  missing intervals and updates only that player's attached layers.
- The toolbar has one **Player** tool. The separate Spotlight tool and the
  Ring/Spotlight/Label shortcut row are replaced by **Player effects**: combine
  ring, spotlight and name label, choose styles and color, then apply together.
  General **Text** remains available for independent notes. Existing saved
  spotlight layers still decode and render normally.
- Reopening the panel reads the player's active effects at the playhead. Apply
  updates existing layers in place, preserving their timing, geometry and motion;
  disabling an option removes its unlocked active layers, with Undo support.
  Locked layers are unchanged. New options bind to the saved track without
  rerunning tracking. When creating several effects for an untracked player,
  process the player once, then attach all requested options.
- Freeze-frame options share optional `playerEffectGroupID` / `playerEffectBox`
  metadata instead of inventing motion. They remain separate timeline layers,
  and the Player panel can reopen them as a group.

Verification: **10 model/footage tests passed on MM iPhone 16** in
`/tmp/analysis-player-panel-release.xcresult`; the completed non-saving phone
walkthrough passed in `/tmp/analysis-player-panel-ui-verified.xcresult` after
fixing test targeting of native switches and same-named track/layer buttons.
It creates two independent tracks, renames and switches between them, adds ring,
label and spotlight through the unified panel without duplicate layers or new
tracking, and preserves the existing layer trim interaction. Actual footage checks
track a blue-shirted and a white-shirted player separately, check the latter's
position at 5 s against the source frame, and render/export both. Inspected phone
panels and the two-player encoded export. No edits were saved to the stress project.

## Reusable clip tracking and mobile refinements — 14 September 2026

- The clip owns an optional, persisted `AnalysisTrackingLibrary`. Named player
  tracks and camera tracks survive deleting a drawing. Existing baked tracks
  are promoted on opening Analysis without rerunning detection. Annotations keep
  render-ready snapshots plus a track ID and their own bind pose; this preserves
  the existing preview/export path and legacy manifests.
- Select a player, add Ring, Spotlight or Label, then add another effect directly
  from the same action row. **Clip tracks** beside Drawing style lists saved
  players at the playhead. Rename a track in the layer inspector. New processing
  runs from the selected frame to the clip end, or until identity is lost. No
  backward tracking is invented. Connections reuse matching saved player tracks.
- Corrections update every attached snapshot, including connection anchors, while
  preserving each layer's placement, timing and smoothing. Locked layers retain
  authored geometry; their shared motion still updates. Undo/redo includes the
  library. Raw samples and explicit occlusion gaps remain unchanged by smoothing.
- Player labels translate from the body centre with a fixed offset instead of
  multiplying their offset by changing detection height. New labels use stronger
  centred smoothing (0.95), also used by legacy labels with no explicit setting;
  the Raw–Smooth control remains available. The filter
  uses an amount-dependent 200–640 ms window without steady-motion trailing lag.
- **Field** adds a four-corner perspective pitch template. Drag corners into
  alignment; crossed or collapsed corners are rejected. It is a visual guide,
  not automatic field recognition, metric calibration or a 3-D camera pose.
  **Use camera track** processes the clip once or attaches the saved motion
  immediately. Drawings placed later get their own reference time. After loss or
  a cut, **Start camera track here** starts a separate track when the old coordinate
  system can no longer be established safely.
- Camera processing registers against one-second key images to limit cumulative
  drift and samples more frequently. It prioritizes the upper scene over moving
  foreground players and cross-checks perspective motion against translation;
  incompatible perspective estimates fall back to verified translation. The underlying API remains Apple's
  [homographic image registration](https://developer.apple.com/documentation/vision/vnhomographicimageregistrationrequest).
  A returned matrix is not proof of accurate field alignment; footage checks must
  include fixed landmarks, not only sample counts or a nil `lostAt`.
- Neon/Pulse spotlights use a translucent overhead beam and a ground halo;
  Clean retains the original dimmed-background spotlight. They can share a player
  track with independent text and rings.
- Preview inspection uses compact icon controls. Removed the “Drag handles to
  reshape · drag inside to move” overlay. Drawing trim handles match the main
  timeline: white 12×38 grips with black slots inside 44-point touch targets.
  The drawing time axis has 24-point side gutters, including at Fit zoom, and
  handles support precise accessibility increments.

Verification: **22 targeted tests passed, zero failures/skips, on iPhone 16 (MM)**
in `/tmp/analysis-reusable-release.xcresult`. This covers saved-track round trips,
legacy promotion, shared correction with preserved bind poses, deletion without
losing tracks, label smoothing/editing, gaps, field projection and invalid corners,
camera direction/cut rejection, and two non-saving stress-project UI walkthroughs.
The actual 3–9.1 s stress segment retained player/camera motion; two fixed background
landmarks were checked at 9 s (within 3% of the frame). Label squared second-difference
jitter was 0.0039× the raw-box value on that segment—this measures jitter, not identity
accuracy or a general tracking success rate. Inspected rendered frames, a 1920×1080
encoded export with shared label/halo/spotlight/field, and phone screenshots in
`/tmp/analysis-reusable-release-evidence`. Earlier in this change, all 12 existing
`AnalysisEditingTests` also passed, including preview/export and identity-loss checks.
The saved phone project was not edited by the walkthroughs.

Limitations: source-time tracks are shared within a clip, not a global player identity
across different recordings. Field alignment is manual; camera motion remains a beta
image-registration approximation and needs inspection during zooms, parallax or cuts.

## Mobile inspector and independent drawing timing — 14 September 2026

- Main-editor drawings have a solid lime duration block and pencil label. Match
  events retain their before/after split and marker. Drawing edges can cross the
  old midpoint; only the owning clip bounds and a one-frame minimum apply.
  Locked drawings cannot be resized. Moving a drawing preserves keyframe IDs
  and never moves source-time tracking samples onto unrelated frames.
- Drawing style uses a native, full-height phone sheet with **Style**, **Timing**
  and **Layer** sections. Controls use readable form rows: relevant appearance
  settings, precise In/Out steppers and playhead actions, then rename/visibility/
  lock/duplicate and a confirmed delete. Zoom omits irrelevant colour and stroke
  settings. Player detection stays out of a selected layer's inspector.
- **Inspect 2×** starts in Pan mode. Drag in either direction, then tap Select to
  place/edit in the magnified view. Fit restores the whole frame. Inspection is
  clamped at the video edges and never changes saved geometry or exported zoom.
- The analysis timeline uses the same icon-only Fit control as the main timeline.
  Pinch or +/- changes scale; drag blank track space to pan. The redundant bottom
  slider is removed. Drag the playhead line anywhere down the track area to scrub;
  intersecting resize handles and keyframe diamonds retain touch priority.
- Layer In is independent of the tracking seed in both timelines and the sheet.
  Static/keyframed layers can extend earlier immediately. Earlier portions of
  tracked layers are orange and remain hidden until tracking exists there; use
  correction at an earlier frame or Static for fixed artwork. No backward motion
  samples are fabricated. Existing tracking data is retained unchanged.

Verification: **66 targeted tests passed on iPhone 16 (MM)** — 61 model/rendering/
main-timeline checks and five non-saving stress-project UI walkthroughs. Includes
pixel comparison of solid drawing versus split event fills, native handles crossing
the old midpoint, earlier In for every motion mode, 2× inspection pan, full-height
playhead dragging, handle/keyframe touch priority, slider-free timeline pan and the
three inspector sections. Result: `/tmp/analysis-mobile-final.xcresult`; screenshots
in `/tmp/analysis-mobile-final-evidence`.
The exact installation build also passed the mobile-inspector/playhead/pan and
tracked-player/In-handle walkthroughs again after keeping Done available during
background tracking: `/tmp/analysis-mobile-installed.xcresult`.

## Polygon editing, timed zoom and stabilisation — 14 September 2026

- **Polygon** is explicit in the tool strip (the persisted `zone` value remains
  compatible). Tap 3–12 corners, then Finish. Select a corner to add a midpoint
  after it or remove it; every authored keyframe gets the same topology edit.
  Player-linked areas keep their tracked anchors and cannot add arbitrary corners.
- Selected rectangles, circles, player markers and spotlights now have four resize
  handles. Arrows/lines expose endpoints, and polygons expose every vertex. Handles
  have 44-point touch targets. Dragging inside moves the whole drawing; editing in
  Keyframes mode updates the current pose. Camera/player attachments are retained.
- **Zoom** creates a timed layer: tap its focus, set 1–4× magnification and an
  ease-in/out duration in Drawing style, then move/trim its timeline bar. Select it
  to edit the focus against the full frame and dashed crop guide; Preview effect
  plays the zoom. Focus can use existing keyframes or player-follow motion.
  Preview/export use one clamped source-space transform for video and drawings.
  The topmost active, visible Zoom layer wins; overlapping zooms do not multiply.
  The separate **Inspect 2×** button is only an editing magnifier, not an export.
- The layer time axis supports pinch zoom anchored under the fingers, plus existing
  +/- and Fit controls. Horizontal drags hold a stable time scale and suppress
  vertical scrolling. Ruler scrubs use coalesced preview seeks, then an exact seek
  on release; automatic playhead scrolling does not fight an active gesture.
- Player and connected-anchor motion defaults to gentle stabilisation. Drawing
  style offers a Raw–Smooth slider. A bounded, centred local linear fit smooths
  feet position and box size over a 240 ms neighbourhood without steady-motion
  trailing lag. Raw samples remain unchanged, and filtering never crosses marked
  recovery gaps. This reduces jitter; it does not fix identity loss or invent a
  track through an occlusion. Workspace overlay playback now observes up to 60 Hz.

Regression coverage includes corner/keyframe editing, polygon topology and stable
IDs, zoom timing/edge clamping/serialization, encoded zoom and overlay alignment,
stress-video source-pixel alignment, synthetic jitter reduction, steady-motion lag
and recovery-gap isolation. Physical-device UI checks exercise the existing stress
project and cancel without saving or resetting its data.

Verification: **53 tests passed on iPhone 16 (MM)**: 49 model/rendering tests and
four non-saving UI walkthroughs, including inward/outward pinch over the whole
timeline, polygon/keyframe editing, timed zoom playback/trim, connected players,
camera lock and the Raw–Smooth slider. Result bundle:
`/tmp/analysis-zoom-verified.xcresult`. Native player touch targets are also
available while constructing connections/linked areas; switching tools no longer
unnecessarily replaces an already detected frame.

## Game-style effects, connections and camera lock — 14 September 2026

- **Player effects:** new rings default to an animated controller marker, segmented
  ground halo and soft beam. Drawing style offers Clean, Neon and Pulse; player
  markers also offer Radar. Animation uses source time, not wall-clock time, so
  scrubbing and exported frames agree. No fabricated speed/distance statistics.
- **Connect:** tap detected players, then Finish. Each endpoint has its own saved
  motion; animated dashes and travelling pulses link their feet. If any endpoint
  becomes untracked, the connection hides rather than freezing. Correct lets the
  user explicitly pick which numbered anchor to replace. Extending the layer
  tracks the added range; Static/Keyframes remain available for manual work.
- **Area:** tap 3–12 corners and Finish. Drag an individual corner to reshape, or
  the interior to move the area. Keyframes animate the vertices. Fill opacity and
  visual style are editable. Turn on Players while constructing an area to attach
  its corners to athletes; the rendered player envelope remains convex when their
  ordering changes. Manual polygons retain authored concave shapes.
- **Track camera (beta):** available in a selected layer's actions menu. Native
  Vision homographic registration samples image motion at approximately 10 Hz,
  storing normalized projective transforms with the annotation. Preview/export
  interpolate the saved transforms. It follows pan/zoom/perspective image motion;
  it does **not** identify pitch lines, calculate metric field coordinates, solve
  3-D camera pose, or separate every parallax plane. Check alignment before saving.
  The action starts at the current frame; restarting discards the earlier camera
  span in that layer. Geometry/registration failure stops the lock. A textured
  image-content check rejects unrelated shots even when Vision returns a plausible
  matrix; this is a safeguard, not guaranteed scene-cut detection.

### Tracking changes and model limits

The existing on-device RF-DETR basketball/player model from Hoops remains bundled;
no new football checkpoint or neural re-identification model has been added.
Selected-player tracking now tries detector recovery before accepting optical
failure, compensates the recovery search for camera motion, and hides short
unconfirmed gaps. A grass-resistant median shirt colour and chromaticity check
handle some exposure changes. Crowded/overlapping identities retain the strict
raw-colour safeguard; a conflicting kit stops the track. Jersey similarity alone
does not identify individuals wearing the same kit.

A six-player ablation on the stress recording (seeds at 3 s, tracking to 12 s)
extended two tracks: stop 6.56 s → clip endpoint 12 s, and 4.26 s → 4.93 s. Four
were unchanged. This is **coverage**, not a six-player identity-accuracy score.
The separately labelled blue-player and blue/white crossing regressions still
check identity: the clear seed follows through the pan, while the crossing stops
at 7.90 s rather than switching players. Warm 9-second tracking jobs took about
1.2 seconds in this fixture; camera registration for 3 seconds took about 0.49 s
including the image-content validation (0.23 s before that safeguard).
These are on-device offline jobs, **not** a measured live-capture pipeline.

The next model step is a football-trained detector and lightweight sports Re-ID
embedding, benchmarked on held-out footage and converted to Core ML. Appearance,
motion and camera compensation are complementary (see
[BoT-SORT](https://github.com/NirAharon/BoT-SORT)). Full pitch coordinates require
field localization/calibration as a separate component (see
[SoccerNet Game State Reconstruction](https://github.com/SoccerNet/sn-gamestate)).
Training data, model licensing, thermal cost and same-kit identity accuracy need
validation before claiming full-match or live tracking.

Device checks include known synthetic camera displacement (including transform
direction), stress-video camera motion, independent endpoint interpolation,
camera-relative geometry edits, saved manifest round trips, time-driven effects,
polygon envelopes and actual encoded preview/export pixel checks. The non-saving
UI walkthrough connects two players, builds and reshapes a polygon, applies
camera lock, changes its style and cancels without changing the saved project.

Verification: 45 tests passed on iPhone 16 (MM): 42 model/rendering tests and
three non-saving UI walkthroughs. Result bundle:
`/tmp/game-analysis-verified.xcresult`. Final bounded-area-rendering checks:
`/tmp/game-analysis-render-release.xcresult`.

## Implemented rebuild — 13 September 2026

The bottom toolbar opens **Analyse** or **Freeze & analyse**. Both open a dedicated
workspace with text, pen, arrows, lines, circles, rectangles, triangle zones,
player rings and spotlights. Tap to place text/highlights; drag to draw or move a
selected layer. Layers support colour, size, duplication, deletion and undo/redo.

The workspace has a shared, zoomable **layer timeline**, with one row per drawing.
Tap the ruler to scrub; drag the upper band of a layer to move it, or its end
handles to trim. Zoom stays around the playhead; the bottom slider pans the time
window. Tap a layer name to select it, use the eye to hide it, or long-press its
name to lock it or change its stacking order.

Selected layers expose three explicit modes:

- **Static:** position the drawing once and set its visible range.
- **Keyframes:** scrub and move the drawing to record a new position, or tap
  **Add keyframe**. Tap diamonds to jump to them; drag them to retime. Previous,
  next and delete controls sit above the timeline. Moving the entire layer moves
  its authored keyframes with it; trimming preserves keys for later extension.
- **Follow player:** pick a player (or draw their box). Existing on-device tracking
  drives the drawing. Blue marks tracked coverage; orange marks missing coverage.
  **Correct** supplies a new player anchor. Extending a successfully tracked
  layer's end automatically tracks the additional range.

Colour, text, layer name, size and advanced timing live in the **Drawing style**
sheet so the video and timeline stay visible while animating. Hidden/locked state,
names and stable keyframe IDs are saved with the existing annotation manifest.

Saving writes annotations into `CompositionClip.annotations` in the existing
composition manifest. Coordinates are normalized to the source display frame;
times use source seconds. Layers appear in the main timeline: select one, adjust
its In/Out handles, choose **Place here**, or reopen it with **Edit layer**. They
follow clip reordering, speed and crop changes, survive reopening, and render into
exported videos through the same drawing code used by the analysis workspace.

Freeze analysis inserts a silent `freezeDuration` clip at the playhead, splitting
the original clip where needed. The hold lasts 1–30 seconds and preserves the
original footage after it. A hold does not duplicate match-event occurrences.

The bundled Hoops sports model runs alongside Vision person/pose detection.
Tap a detected player, then **Ring**, **Spotlight** or **Label**. Effects attach
automatically and track every decoded frame for their duration (six seconds by
default). A dedicated Vision object tracker follows the selected image region;
full-body Hoops detections every 0.3 seconds counter drift toward the torso.
Overlap and jersey-colour checks gate those corrections. Additional effects can
reuse the selected layer's saved motion. Drawing around a missed player also
starts tracking. No separate “Follow” or motion-cache step is required.

**Preview effect** replays the layer. Drag its timeline end or use **To clip end**
in Drawing style to extend and track its duration. **Correct** accepts a tap or a manually drawn player box at
the current frame. Lost/untracked spans are hidden, including gaps before a
manual correction. Motion is saved with the edit, independently of detection
caches, and used by preview/export. Timeline placement changes visibility within
the tracked source range; it never shifts player samples onto unrelated frames.
Long occlusions, same-kit crossings and camera cuts can still break identity;
this is assisted tracking, not guaranteed full-match player identification.

The workspace prioritizes the video, layer timeline and contextual player actions.
**Zoom 2×**
enlarges the canvas around the selected player without changing the saved crop.

Automatic event tagging, metric ball/pitch calibration and segmentation-based
player cutouts remain future work. Camera registration and multi-player
connections were added in the 14 September update above. The spotlight is a
drawn oval, not a player segmentation mask.

### Verification

- 34 tests passed on the connected iPhone 16 (MM), including real-device UI
  walkthrough: annotation persistence,
  interpolation, legacy manifests, timed rendering, pixel checks on an exported
  file, freeze/resume behaviour, player tracking helpers, playback and timeline
  regressions.
- The layer-timeline walkthrough draws two layers, switches to keyframes, edits
  a drawing at another time, zooms, moves its bar, drags an individual diamond,
  trims its end and selects the other layer. Tests check stable keyframe IDs,
  trim/extension, locked edits and source-aligned automatic motion. A moved
  keyframed drawing is also checked in both preview and encoded export.
- Actual stress-project soccer recording `EBB12192-62DB-495B-A6CE-218F0C420A74.mov`,
  sampled at 3 seconds: 16 detections. The saved diagnostic image was inspected;
  this is a sampled-frame check, not a full-match accuracy claim.
- Selected blue player followed from 3–9 seconds in that recording, through
  running and a camera pan. Positions at 3, 5, 7 and 9 seconds were checked
  against manually read source-frame foot positions. The test also reopens the
  serialized motion and checks the ring in preview and encoded export at three
  moving positions. Plain optical tracking failed this test (ring drifted above
  the feet); the detector-assisted implementation passed.
- An overlapping blue/white player case stops at 7.9 seconds after a 6.6-second
  seed instead of continuing on the wrong shirt. Manual correction is needed
  for that case; it is not counted as a successful continuous track.
- Device UI walkthrough opened the existing stress-project soccer source without
  resetting/seeding data, selected a player, added a ring with automatic tracking,
  previewed its duration, and cancelled without changing the saved project.
  The final layer-timeline regression run is `/tmp/layer-timeline-release.xcresult`.
  This UI check verifies selection, automatic attachment and playback, not
  continuous identity: the selected player in this walkthrough needs correction
  at 6.2 seconds. The separate seeded 3–9-second tracking test above checks
  continuous motion against known positions.
- Simulator walkthrough using a copy of that recording: created and edited text,
  saved it to the timeline, selected its timing handles, reopened the saved edit,
  tapped a manual player highlight, and inserted a freeze clip containing text
  and the highlight. The 33-second sequence became 38 seconds with a 5-second hold.

Tests: `CamelotTests/AnalysisEditingTests.swift`, `AnalysisLayerTimelineTests.swift`, `PlayerAnalysisTests.swift`,
`EditorSequenceMediaTests.swift`, `TimelineGeometryTests.swift`.

## Original feasibility notes and future feature plan

The following measurements predate the sports model integration. They describe
Apple Vision request costs on earlier test fixtures, not current end-to-end
performance or accuracy on the soccer stress-test footage.

### Original architecture baseline

- Recordings are immutable segments; events carry `offsetSeconds` plus pre/post-roll.
- Compositions are clip manifests (`recordingID`, `startSeconds`, `endSeconds`, `rate`).
- The editor plays through an `AVPlayerLayer`; the timeline is seconds-based geometry.
- Sync moves small records for `project`, `media`, `event`, `collection`, `summary`.

The rebuild above stores annotations and freeze metadata in the existing clip
manifest rather than introducing another synced record type. Source video is
never rewritten.

## Measured on-device model costs (Apple Vision, no custom model)

| Request | 1280x720 | 1920x1080 | Verdict |
|---|---|---|---|
| Person boxes (`VNDetectHumanRectangles`) | 5.8 ms | 6.9–7.5 ms | Real time |
| 2D body pose, all people | 7.0 ms | 10.5–11.4 ms | Real time |
| 3D body pose (one athlete) | 103.8 ms | ~102 ms | Offline per clip only |
| Ball trajectories (`VNDetectTrajectories`) | 4.9 ms | 24–36 ms | Fast but unusable on handheld footage: thousands of false trajectories and "too many moving objects" errors |
| Foreground subject mask | 26.6 ms | 12.3–12.6 ms | Real time for spotlight effect |
| Optical flow (low accuracy) | 45.7 ms | ~47 ms | Offline only |
| Object tracking (`VNTrackObject`) | not measured (no person in first sampled frame) | | Known cheap; verify on match footage |

Detection counts in the original benchmark were near zero because its fixtures
did not contain players. See the rebuild verification above for the soccer check.

## Feature tiers

### Tier 1 — Telestration, no ML (ship first)

- Freeze frame: hold a frame for N seconds inside a composition (`holdSeconds` on a clip).
- Draw on the frame or on moving video: pen, arrow, line, circle, rectangle, text, zone polygon.
- Player highlight ring (perspective ellipse under the feet), spotlight (dim everything except a region).
- Connect players: pick N anchor points, draw lines or a filled shape between them.
- Draw-on animation and per-item timing inside the hold window.
- Playback helpers: frame step, loop range, slow motion (rate already exists).
- Export with annotations burned in; annotations sync as their own records.

### Tier 2 — Built-in Vision models (measured, ready)

- Tap a player to track them; annotations anchored to the track follow automatically.
- Skeleton overlay from 2D pose; joint-angle tool for technique review.
- Team colour auto highlight (cluster torso colours of detected people).
- Subject spotlight from the foreground mask instead of a hand-drawn shape.

### Tier 3 — Custom model and calibration

- Ball detection and tracking with a small Core ML detector (YOLO-class, ~640 input) plus a Kalman filter. Vision's trajectory detector is not viable for this footage.
- Pitch calibration: tap four or more known pitch landmarks once per camera position, solve a homography, then measure distances and speeds, draw an offside line, and show a top-down mini-map of tracked players.
- Jersey number reading with `VNRecognizeText` on torso crops (low confidence at distance; optional).
- Event suggestions from pose plus ball (roadmap phase 5), always human-confirmed.

### Tier 4 — Later

- Side-by-side comparison of two clips.
- Voice-over on annotated clips.
- Set-piece templates.
- Annotations rendered in the web player from JSON overlays.

## Architecture

**Data.** New sync entity `annotation` with parent `media` (the recording).
Time is in source-recording seconds so annotations survive re-editing.
Coordinates are normalised 0–1 in the recording's frame. Items are a list of
primitives with style and either a static anchor or a `trackID` anchor.
Freeze is a composition-level clip attribute, not an annotation.

**Rendering.** Preview and export share one `CALayer` tree: `AVSynchronizedLayer`
drives it during playback and `AVVideoCompositionCoreAnimationTool` burns it in
on export. Mask-based spotlight needs a custom `AVVideoCompositing` (Metal); a
plain radial dim does not, so start there.

**Analysis.** One background `AnalysisJob` per recording reads frames at 720p
with `AVAssetReader`, runs person detection every frame and the tracker in
between, and writes tracks to a sidecar file. Tracks are derived data and are
not synced; the server can regenerate them later (roadmap: server-side
authoritative models). Gate on device capability and throttle on
`ProcessInfo.thermalState`.

## Status (13 Sep 2026)

Tier 2 player tracking is implemented on iOS:

- `RecordingAnalysis.swift`: sidecar model, overlap tracker, team-colour clustering, frame mapping, JSON store under `Documents/Analysis`.
- `AnalysisEngine.swift`: person boxes + 2D pose per frame at up to 30 fps, 1280 px decode, thermal throttling, cancellation. Pose falls back to boxes only where the model cannot load.
- `AnalysisOverlayView.swift`: boxes tinted per team, skeletons, tap a player to follow them with a ring under the feet; the Analyse menu sits on the preview.
- The editor analyses the trim selection or the clip under the playhead; results persist and reload with the recording.

Measured on the iPhone 16: 4 s of 720p footage analyses in 2.6 s including decoding, about 22 ms per frame.

Decisions taken from Miguel's answers: tripod-first but handheld must work (tracking uses per-frame detection, not a fixed-camera assumption); burned-in export only for now; iOS 17 floor with capability gates (`AnalysisCapabilities`) for the newer Vision API and on-device language models; analysis is on demand after the session, not live.

Known limits: Vision cannot create an inference context on the iOS simulator, so all model tests skip there and the UI test runs on a device. Tracks are not synced.

## Open questions

1. Should the "follow this player" selection be saved as an annotation record so it survives closing the editor and reaches exports?
2. Scoreboard overlay: a per-project score state stamped on exports, or a live element during capture?
3. Which league or footage should train the ball detector for tier 3?
