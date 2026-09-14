# Camelot iOS

Native SwiftUI client shell. Generate and build with:

```bash
xcodegen generate
xcodebuild -project Camelot.xcodeproj -scheme Camelot -destination 'generic/platform=iOS' build
```

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

Camera zoom opens a compact arc dial: tap the magnification or drag left/right,
with haptics at common zoom factors. It collapses after three seconds of inactivity,
uses logarithmic spacing, respects hardware limits, and supports VoiceOver adjustment.
After tagging, a countdown follows the movie clock through the event's post-roll.
End now saves a shorter event window without stopping full-video capture. Overlapping
windows retain separate deadlines; the countdown menu selects which event to end.
Replay capture saves and resumes buffering once the last pending event ends. Device
tests use short temporary captures to verify both modes and remove their test files.

The editor's Add event button toggles a compact event row above the workspace.
Tagging inserts at the playhead without pausing playback or rebuilding the preview;
assembled clips map the current output position back to the correct source and speed.
Timeline pinches keep the playhead fixed, including off-center gestures and release.
