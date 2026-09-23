# Camelot iOS

Native SwiftUI client shell. Generate and build with:

```bash
xcodegen generate
xcodebuild -project Camelot.xcodeproj -scheme Camelot -destination 'generic/platform=iOS' build
```

Use `-configuration Release` for physical-device performance validation and
everyday analysis testing. Debug's unoptimized Swift feature-matching loops are
substantially slower and are not representative of tracking performance. Keep
Debug available for breakpoint-driven debugging; do not disable optimization in
a build used to evaluate camera-tracking speed. For hosted unit tests of Release,
add `ENABLE_TESTABILITY=YES`. Install the app from `Release-iphoneos`, not an older
`Debug-iphoneos` product, after verifying it on the phone.

The simulator API defaults to `http://localhost:3000`.


Editor checks:

```bash
TEST_RUNNER_CAMELOT_SAMPLE_VIDEO=/absolute/path/to/video.mp4 xcodebuild test \
  -project Camelot.xcodeproj -scheme Camelot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CamelotTests -only-testing:CamelotUITests/EditorInteractionTests
```

The debug fixture creates a separate **Editor stress test** project with 240 events.
Interaction tests cover filtering, note search, panel resizing, event deselection,
clip trimming, splitting, reordering, undo, pinch zoom, and rotation. Geometry tests
include two-hour recordings, sub-second trim bounds, panel sizing, and overlapping
event tracks. Interaction tests skip without a video path.

The timeline uses a virtual `UIScrollView` and a viewport-sized drawing surface.
Thumbnail requests are coalesced, decoded sequentially, and retained in a bounded
cache; pinch gestures reuse existing images. Events show their entire pre-roll and
post-roll windows on separate tracks when they overlap. Track placement is cached;
only visible ranges are drawn. Event rows are lazy and isolated from playback updates.

The editor has a preview and one workspace, with Timeline / Event list views of the
same assembled video. The timeline shows every clip end to end, with its event
windows underneath on the same time ruler. The list includes event occurrences
from all clips and preserves selection and playback position when switching views.

Clip trims, speed changes, repeats, and reordering are reflected in event positions.
Windows crossing a cut show the retained portions under each clip. Occurrence IDs
include both clip and source event IDs; editing a window updates the original source
event using the clip's playback rate. Playback uses one composed player item and a
stable content task key, so selecting or editing events does not rebuild the preview.

Drag the grip between preview and workspace (or the side grip in landscape) to resize
using fixed screen coordinates. Clip trim, split, speed, and crop controls are directly
available below the timeline. Source range trimming opens in the same workspace.
The footage picker can add a full recording, a custom clip range, or an event window.
Save offers the complete edit, selected clip, or selected event.

Device unit tests include an actual render of reordered, trimmed clips at different
speeds, using a tiny generated red/blue fixture. Run without simulators with:

```bash
xcodebuild test -project Camelot.xcodeproj -scheme Camelot \
  -destination 'platform=iOS,id=YOUR_DEVICE_UDID' -only-testing:CamelotTests
```

The camera keeps event targets in place before and during recording, with event
counts and brief visual/haptic acknowledgements. The full camera frame sits behind
compact top and bottom overlays, with a single row of event targets in both
orientations. Quality is directly accessible; recording mode, grid, and torch are
in Camera options, with grid and torch also exposed in landscape. Rotation retains
the same preview layer, session connection, and rotation coordinator. Capture
orientation is set once at the start of each file, rather than repeatedly changing
the movie output while the phone rotates. Stopping recording asks for confirmation before saving or discarding an unused replay buffer.
On iOS 18 and newer, pause/resume keeps the same file open and freezes the movie
clock and event countdowns; the stop target becomes smaller once recording starts.
The quality menu exposes 720p, 1080p, and 4K when supported by the active capture
session and reports the applied preset. Configuration and saving states prevent
conflicting actions. Camera permission recovery links to Settings, and returning
from the background reuses the existing capture inputs.

Account → Appearance offers System (default), Light, and Dark. Changes apply
immediately and persist between launches. Camera and editor surfaces stay dark.
Device tests cover live appearance changes and persistence, compact camera control
layouts, 4K session configuration when available, and camera shutdown/reopening.
Recording quality and audio still need a real recording check on a physical device.

Camera zoom works like Camera.app. A row of lens pills above the shutter lists the
active device's meaningful factors (0.5×, 1×, 2×, 3× or 5× from the virtual device's
switch-over factors, clamped to the hardware range; a single-lens device shows 1× and 2×).
The selected pill shows the live factor to one decimal and tapping a pill ramps to it.
Holding or dragging the row opens a horizontal precision ruler with logarithmic ticks
and labelled stops that follows the finger, clicks at lens stops, snaps to a stop on
release, and collapses after two seconds of inactivity. The selected pill and the open
ruler share one adjustable VoiceOver element ("Camera zoom", `camera-zoom-dial`).
Pinching the preview zooms from the current factor with the same haptics and a brief
factor HUD; double tap returns to 1×. Zoom keeps working while recording and survives
rotation. Tap to focus draws a yellow reticle at the point, switches focus and exposure
to continuous modes there, and shows a sun slider beside it that drags vertically to set
exposure bias within the device's range; both fade after a few seconds. A long press locks
AE/AF with an "AE/AF LOCK" badge until the next tap. A clear downward swipe or the chevron
closes the camera when nothing is recording. The gestures live on the preview view, so
event targets and the shutter never lose touches. `CameraZoomModelTests` cover the pill
derivation, ruler and exposure maths; `CameraGestureTests` drives pills, pinch, focus and
lock on a phone.
After tagging, a countdown follows the movie clock through the event's post-roll.
End now saves a shorter event window without stopping full-video capture. Overlapping
windows retain separate deadlines; the countdown menu selects which event to end.
Replay capture saves and resumes buffering once the last pending event ends. Device
tests use short temporary captures to verify both modes and remove their test files.

The editor's Add event button toggles a compact event row above the workspace.
Tagging inserts at the playhead without pausing playback or rebuilding the preview;
assembled clips map the current output position back to the correct source and speed.
Timeline pinches keep the playhead fixed, including off-center gestures and release.

Pitch setup (Analyse → Pitch) is one sheet, "Line up the pitch": it starts detecting
on open, snaps the pitch template to the painted markings and ends in **Looks right**
or **Try again**. The method menu, numbered handles, trace lines, nudges and
dimensions are under **Adjust by hand**. Synthetic simulator coverage lives in
`CamelotTests/PitchRegistrationTests` and `CamelotUITests/FieldSetupUITests`;
real-footage proposals run on the phone only. The Analyse workspace itself is
described in `docs/annotation-and-analysis.md` (task-first workspace section).

## Player tracking

Following one player is an incremental pass. `SelectedPlayerTracking.track(…direction:…
checkpoint:)` publishes the frame it has reached and, about every 0.4 s, a complete `PlayerMotion`
of everything confirmed so far; the editor moves the preview to that frame and folds the partial
into the clip's tracking library every couple of seconds. **Stop** keeps that partial track (the
pass returns `stopped`, not an error) and ends the track cleanly at the stopped frame. Re-tracking
from the playhead in either direction replaces only the section the pass covers: forward splices
through `PlayerMotion.continuing(with:from:)` and backward through `prepending(_:seed:)`, so the
saved past and future survive. The stored format is unchanged, so older tracks need no migration.

In the Analyse screen a highlight follows its player through the whole clip
automatically (forward with the video, then back to the start), and **Fix** is the
only repair: tap the player on any frame. Inside a lost part only that part is
filled; on a followed frame the track re-follows from there. See the task-first
workspace section in `docs/annotation-and-analysis.md`.

Sampling is capped at `PlayerTrackingLimits.maximumSampleRate` (30 Hz); 60 fps sources are tracked
every other frame, and sources at or below the cap keep every frame. Every frame runs inside an
`autoreleasepool` — without it a five-minute pass reached 2.2 GB and was killed; it now peaks
around 145 MB. Decoding to a lower resolution is deliberately *not* done beyond the existing 1280
long side: measured on the phone, the detector's CoreML input is a fixed size so resolution does
not change inference cost, and decode is 1–7 ms from 480p to 4K. `CamelotTests/PlayerTrackingBenchmark`
re-runs those measurements on the phone (stage profile, decode cost by size, forward/backward
throughput, a 60 Hz-vs-30 Hz A/B, and an opt-in five-minute reproduction with memory sampling);
`CamelotTests/IncrementalTrackingTests` covers the pipeline, with the Vision parts skipping off-device.

## Tactical board

Boards live in their own **Boards** tab (`TacticalBoardsView`): a searchable card grid with a
**New board** menu (full pitch, half pitch, futsal, basketball, blank) and rename / duplicate /
delete. Boards are independent of projects. `TacticalBoard` is a SwiftData model whose content is
a versioned Codable `BoardDocument` (`TacticalBoardModels.swift`); every property added after the
first release is Optional so older boards still decode (a real phone board is a test fixture).
The model once had a `projectID`; dropping it is a lightweight migration, verified against a copy
of a phone store (`testPhoneStoreSnapshotMigrates`, run with
`TEST_RUNNER_CAMELOT_BOARD_STORE_SNAPSHOT=<folder>`) and a synthetic legacy store.

Coordinates are normalised 0…1 over the field. Elements carry `rotation` (degrees, clockwise,
0 faces +x) and `size` (0.4…3), both animated by keyframes (shortest-arc rotation). Point
elements are sized in `BoardFieldType.elementUnitMeters` (1% of the short side) so 2D, 3D and
line trimming agree. Lines are `line` (2 points, optional quadratic control), `polyline` and legacy
`arrow`/freehand `line`, all drawn from `lineVertices`/`curveControl` with a `BoardLineStyle`
(pattern, straight/wavy/zigzag, start/end caps, width, opacity). Line ends can attach to point
elements; `BoardDocument.elements(at:)` resolves attached ends, and deleting an element leaves
its lines at its last position.

**Views.** Top is drawn in 2D by `BoardRenderer`, the single source for the editor canvas,
thumbnails and 2D exports. Tilted and Broadcast are real 3D (`TacticalBoard3DView`, SceneKit) with
an orbit camera stored in the document. Placing tools switch back to Top.
`BoardSurfacePainter` (`TacticalBoardSurface.swift`) paints the five field styles (grass,
floodlit, classic, chalkboard, indoor court) with markings and goals in metres; the 2D renderer
caches that surface per field/style/pixel density and the 3D scene uses it as its ground texture
(`BoardRenderer.surfaceImage`).

**Editor** (`TacticalBoardView`). A UIKit touch surface (`TacticalBoardTouchSurface.swift`) gives
one-finger edits and true two-finger pinches: pinching zooms around the point between the fingers
and pans with them; a pinch that starts on the selected element rotates (15° magnetic snaps) and
scales it instead, and never moves the element under the first finger. Selected elements show
rotate/resize handles (44 pt targets), lines show end handles, a bend handle (double-tap
straightens) or polyline insert handles (long-press a vertex to delete). Releasing a line end
within 28 pt of an element connects it. The inspector has colour, line style, border and
Size/Width + Rotation sliders; every gesture or slider drag is one undo step and records the pose
in the current keyframe. Autosave is debounced and never mid-gesture; thumbnails
(`<id>-v2.png`) are written on close or rendered by the card when missing.

Tests: `CamelotTests/TacticalBoardTests` (set `TEST_RUNNER_CAMELOT_BOARD_GALLERY=<folder>` to
render every field × style for design review) and `CamelotUITests/TacticalBoardUITests`. The UI
test names its boards "UITest …" and launches with `-removeUITestBoards`, which deletes only those
boards and thumbnails; it never resets onboarding, so it is safe on a phone with real data.

## Squad

The **Squad** tab (`SquadView`) stores players: name, number, position and role, team, foot,
birth year, height, kit colour, notes and a photo. `SquadPlayer` is an additive SwiftData model
(verified against a copy of a phone store, `SquadTests.testPhoneStoreSnapshotOpensWithSquadSchema`).
Photos (`SquadPhotoStore`) are 512 px square JPEGs at `Documents/SquadPhotos/<id>.jpg`, cropped
around the largest Vision face (else centred) and excluded from iCloud backup; `image(for:)` is
thread-safe and cached, so 2D/3D renderers and exports call it from any thread.

Boards link people through the Optional `BoardElement.playerID`. The library lists squad players
(tap to place). **Add lineup** (`SquadLineupSheet`) places a 4-3-3, 4-4-2, 4-2-3-1, 3-5-2 or 3-4-3
for Home (own half) or Away (mirrored, away colour) as one undo step: selected squad players take
slots of their position, ordered across each line by role from the team's own right (computed in
field space from its goal: RB, RCB, CB, LCB, LB; RM … LM; RW, ST, LW; unknown roles central), and
"Fill empty slots" adds players with conventional numbers per slot (`SquadFormation.conventionalNumbers`,
e.g. back four 2, 5, 4, 3 and front three 7, 9, 11), or the lowest free number when that side already uses one. "Fill remaining" (also "Fill team…" in the element card's Squad tab) adds players only to
slots no same-side player covers within ~10% of the short side; existing players never move. Opening a board refreshes linked numbers, labels and keeper/outfield
kind; elements of deleted players keep theirs. Linked discs draw the photo with a number tab.
The inspector links, relinks or unlinks a player.

Tests: `CamelotTests/SquadTests` and `CamelotUITests/SquadUITests`. The UI test launches with
`-seedUITestSquad` (players named "UITest …" in team "UITest", with generated photos) and cleans up
with `-removeUITestSquad`, which deletes only those players and photos.

## Multi-cam sessions

Several phones can work one match together over MultipeerConnectivity (same Wi‑Fi, or a direct
link when close together; `NSBonjourServices` lists `_camelot-cam`). The host opens a project →
More → **Multi-cam session** and picks a mode; other phones use Projects → **Join a session**.
Every message carries host-clock seconds: peers keep an NTP-style offset (`MultiCamClockSync`,
best-round-trip median) so events and recording starts line up within a few milliseconds.

- **Event remote** — the host records with the normal camera (`CameraCaptureView` with
  `multiCamMode`); remotes (`MultiCamRemoteView`) tag events that land on the host's active
  segment at `currentOffset − (now − tapTime)`. A lime chip top-right counts connected remotes.
- **Two cameras** — the second phone (`MultiCamCameraView`) records full quality locally and
  streams a 720p H.264 feed (`MultiCamVideoEncoder`, VideoToolbox, keyframe every second, SPS/PPS
  on every keyframe) that the host shows as a swappable picture-in-picture. Start and stop are
  synced; after stop the file is sent peer-to-peer (`MCSession.sendResource`) and saved into the
  same project with `multiCamRole = camera` and `multiCamOffsetSeconds` from the two first-frame
  times. **Create wide view** on that video (`MultiCamStitchView`) registers a few shared frames
  (`MultiCamRegistration`: a normalized cross-correlation search over downscaled greyscale finds
  the shift — Vision's `VNHomographicImageRegistrationRequest` only handles small misalignments
  and returned garbage for a 960 px shift — then Vision refines the residual on the overlap),
  renders every main frame with the warped second frame behind it and a feathered seam
  (`MultiCamStitcher`); implausible registrations fall back to side by side. Registration
  assumes the two phones share roughly the same zoom. The result is a normal recording, so the editor's zoom works on it.
- **Multi-cam switcher** — the host (`MultiCamCaptureView`) shows every feed as a thumbnail and
  cuts by tapping; `MultiCamCaptureEngine` writes the host's own full-quality file plus a 720p
  program file from either its own frames or the decoded remote frames, and saves the
  `MultiCamSwitchTimeline` on the program recording so a full-quality cut can be rebuilt later.

**Companions.** `CamelotCamera` (target in `project.yml`, iOS 16+, bundle `com.blacknosaur.camelot.camera`, signed by the Blacknosaur SC team `9V4MJ8TDVJ` because `com.camelot.evolve.camera` is registered to the personal team)
is the same peer code as a standalone app for older iPhones: it shares the multi-cam files plus
`DesignSystem`, `EventKind`, `EventTagStrip` and `CameraControls` (so those must stay iOS‑16
clean: `Capsule()`/`RoundedRectangle` rather than `.capsule`/`.rect`, no `@Observable`), and
keeps recordings under Documents/Recordings. `clients/android` is the Android companion; because
Multipeer is Apple-only, the host also runs `MultiCamSocketServer` (TCP + Bonjour
`_camelot-sock._tcp`, same wire format, tag 3 = file chunk) which any non-Apple camera uses.
`CamelotUITests/MultiCamHostUITests` drives the phone as a host against a real companion (start the
Android app with `adb shell am start -n app.camelot.camera/.MainActivity --ez autoJoin true`) and
checks join → take → transfer; it creates and removes a "UITest Multi-cam" project.

**Aiming two cameras.** In a two-camera session the host's header has a side-by-side toggle
(`multicam-align-toggle`): both views at equal size with a seam between them, plus a live readout
driven by `MultiCamAlignmentCheck`, which runs the stitcher's own `MultiCamRegistration.coarseShift`
on downscaled live frames every 1.5 s. It reports the shared percentage ("15–55% shared" is what
the stitcher needs), which side the second camera is on, and whether one phone is aimed lower, so
the wide view is checked before the match rather than after it.

Cameras and the switcher host capture through `AVCaptureVideoDataOutput` + `AVAssetWriter`
(`MultiCamCaptureEngine`), not `AVCaptureMovieFileOutput`, because they need every frame; the
files still use one-second fragments and the crash-recovery journal. Transfers need both apps in
the foreground. `CamelotTests/MultiCamProtocolTests` covers the wire format, clock sync, switch
timeline, alignment, stitch layout, registration and an encoder → decoder round trip.
`CamelotTests/MultiCamDeviceTests` (phone only) runs host and peer sessions in one process over a
real Multipeer link, records with the engine including a program cut, and stitches two synthetic
overlapping clips. Transfer and stitching on real footage still need two phones.
