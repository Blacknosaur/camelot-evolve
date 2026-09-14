# Annotation and on-device analysis

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
