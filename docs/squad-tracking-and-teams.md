# Squad tracking and team assignments

## What caused the inflated count

The physical-phone baseline on the 32.5-second soccer stress clip produced **46 saved motion tracks**, with a peak of **17 tracked people in one frame**. Lost players, uncertain returns and occasional duplicate detections create separate segments. The saved-track count therefore cannot serve as a unique-player count.

Rerunning the first eight seconds with the saved roster added two more tracks. The roster only initialized saved positions at the beginning of a pass; players first seen later could be created again.

## Changes

- Reruns use saved observed positions at the corresponding source time, including late entries. Appearance compatibility and exclusive ownership still gate assignments. Inferred positions are excluded.
- The 48-track resource limit applies to active identities. Historical fragments and their stale positions cannot prevent new entrants from being discovered.
- Saved tracks have an optional, explicit **Team A**, **Team B** or **Referee** assignment. Existing records decode as **Unassigned**. Assignments survive tracking repairs and roster refreshes.
- **Squad tracks** groups the records by assignment and shows the number tracked in the current frame separately from the total number of saved tracks.
- **Link same player…** combines user-confirmed segments into the chosen saved player. It preserves the target name, manual picks, gaps where neither track saw the player, and attached effect bindings. Different assigned teams or incompatible simultaneous positions cannot be linked. Assignment and linking use the editor's Undo checkpoint.

## Use

Open the player-track list. Use the people/gear button beside a track to assign its team or Referee. Select a track to review its position on the video. Once two sections are confirmed as the same person, open the track's **… → Link same player…** menu and choose the saved player to retain.

Team assignment is manual. It does not train a team classifier or prove which same-kit teammate returned. Link only after reviewing the footage; use the existing frame review or redo controls for conflicting positions.

## Verification

The tests use the existing recording read only and in-memory clips. They do not save test changes into the stress project. Coverage includes late-entry reruns, incompatible kits at saved positions, historical track capacity, legacy decoding, team persistence, link conflicts, manual pick precedence, and effect rebinding. Full-clip contact sheets are reviewed alongside counts so reducing the count cannot substitute for identity checks.

A pending-observation recovery experiment reduced the full-clip count from 46 to 45 but shortened the original blue runner's continuous identity. It was rejected. The full-clip test now checks that runner at 6.5, 9.8, 12 and 18 seconds as well as checking rerun duplication.

Final Release build on the physical iPhone (20 September 2026): **75 tests passed, zero failures**, including two footage tests and native UI rendering. The original blue runner passed the added source-frame checks. Contact sheets were inspected at 0.7, 3, 6.5, 9.8, 12, 18, 25.5 and 30 seconds.

| Measure | Baseline | Final |
| --- | ---: | ---: |
| Full-clip saved segments | 46 | 44 |
| Peak tracked in one frame | 17 | 17 |
| New duplicates on 0–8 s rerun | 2 | 0 |
| New duplicates on 3–6 s rerun | 3 | 0 |
| Full squad pass, excluding camera generation | 33.76 s | 30.32 s |

These are individual phone runs, not controlled thermal/performance averages. The count remains above the number of unique players; long-return fragmentation is still present.

Verification result: `/tmp/camelot-squad-verified.xcresult`; log: `/tmp/camelot-squad-verified.log`. Screens and footage contact sheets: `/tmp/camelot-squad-verified-attachments/`.

The verified build was explicitly **installed and launched as Camelot Review**, `com.blacknosaur.camelot.evolve.review`, using Blacknosaur SC signing. Install and launch logs: `/tmp/camelot-squad-install.log`, `/tmp/camelot-squad-launch.log`. The original app was not replaced.

Native team screens rendered on the phone. The interactive gesture walkthrough remains unverified: the previous UI runner was blocked by iOS's **Enter iPhone Passcode for XCTest — Enable UI Automation** prompt. Model tests and native rendering do not establish that gesture walkthrough.

## Remaining limitations

Automatic segmentation still produces fragments after occlusion and long exits. There is no forced 22-player cap or automatic merge based only on kit color. The system can also miss distant players or detect partially overlapping body fragments. The team groups and link action provide explicit correction; they do not make automatic re-identification perfect.
