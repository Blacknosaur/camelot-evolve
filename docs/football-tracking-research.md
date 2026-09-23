# Soccer identity tracking: repository and paper review

Reviewed 20 September 2026. This follows the user's report of opponent and teammate identity switches. The earlier phone tests in `soccer-tracking-review.md` did not establish reliable same-team identity through all crossings or validate every rendered gap.

## Football-Tracking repository

Reviewed [AnshChoudhary/Football-Tracking](https://github.com/AnshChoudhary/Football-Tracking/tree/87ff3b4b9393346674df78bd0368fac97d6612b4), commit `87ff3b4`.

Its useful ideas are soccer-specific detection, separation of image and field coordinates, and explicit camera-motion estimation. Camelot already has corresponding components. It is not an individual-identity upgrade for this app:

1. **Team labels cannot prevent switches.** [tracker.py](https://github.com/AnshChoudhary/Football-Tracking/blob/87ff3b4b9393346674df78bd0368fac97d6612b4/trackers/tracker.py#L12) uses `sv.ByteTrack()` without a player appearance model. [main.py](https://github.com/AnshChoudhary/Football-Tracking/blob/87ff3b4b9393346674df78bd0368fac97d6612b4/main.py#L43) assigns teams after tracking. [TeamAssigner](https://github.com/AnshChoudhary/Football-Tracking/blob/87ff3b4b9393346674df78bd0368fac97d6612b4/team_assigner/team_assigner.py#L59) caches a team by track ID forever and hardcodes ID 91 to team 1. A switched track can therefore retain the old team's label. Two white shirts receive no individual signature.
2. **Camera compensation is unsuitable for our pans and field effects.** [CameraMovementEstimator](https://github.com/AnshChoudhary/Football-Tracking/blob/87ff3b4b9393346674df78bd0368fac97d6612b4/camera_movement_estimator/camera_movement_estimator.py#L54) chooses the largest feature displacement, ignores optical-flow status, and subtracts one frame's translation from positions. It does not accumulate a reference transform or model zoom/projective changes. Feature masks also use fixed pixel columns.
3. **Calibration and time are clip-specific.** [ViewTransformer](https://github.com/AnshChoudhary/Football-Tracking/blob/87ff3b4b9393346674df78bd0368fac97d6612b4/view_transformer/view_transformer.py#L5) hardcodes four image points and field dimensions. [SpeedAndDistance](https://github.com/AnshChoudhary/Football-Tracking/blob/87ff3b4b9393346674df78bd0368fac97d6612b4/speed_and_distance_estimator/speed_and_distance_estimator.py#L7) assumes 24 fps. These cannot be carried into arbitrary phone clips.
4. **The checked-in entry point needs repair before a benchmark.** Its call to `draw_annotations` omits required `team_ball_control`; possession can index an empty previous-value list. The README references `requirements.txt` and `LICENSE`, and the code imports `utils`, but those files/modules are absent from the reviewed tree. I reviewed the code; I did not run its demo as a valid end-to-end comparison.

## Papers and concrete applications

These are proposed adaptations unless explicitly marked implemented below; paper results are not Camelot measurements.

| Paper | Useful contribution | Application here |
| --- | --- | --- |
| [PRTreID / PRT-Track](https://arxiv.org/html/2401.09942v1) | Joint identity, team and role representation; visible-part features; tracklet relinking | Best reference for a soccer-trained individual signature. Keep team compatibility and individual identity distinct. Evaluate same-team negatives before adopting a model. |
| [BPBreID](https://arxiv.org/abs/2211.03679) | Body-part representations for occluded people | Compare only visible parts. Hidden legs should not contaminate a signature or become measured foot positions. |
| [Deep OC-SORT](https://arxiv.org/abs/2302.11813) | Adaptive use and updating of appearance information | Freeze appearance updates when evidence is degraded or assignment is ambiguous. Preserve trusted history during a crossing. |
| [BoT-SORT](https://arxiv.org/abs/2206.14651) | Motion, appearance and camera-motion compensation | Keep the existing camera-aware motion prediction, with appearance gates and exclusive player assignments. |
| [SoccerNet Game State Reconstruction](https://arxiv.org/abs/2404.11335) | Joint evaluation of detection, identity, jersey/team information and field localization | Evaluate effects on the correct player and correct field location, including after storage/export. |
| [SportsMOT / MixSort](https://arxiv.org/abs/2304.05170) | Sports sequences with similar appearance and fast nonlinear movement | Benchmark association with IDF1, HOTA/AssA, identity switches and missed coverage, rather than fixed track counts or agreement between two trackers. |
| [OSNet](https://arxiv.org/abs/1905.00953) | Small person-ReID network | A mobile candidate to measure, not an automatic replacement for Vision. The probe below found a teammate confusion. |

The newer [SRITrack paper](https://doi.org/10.1016/j.eswa.2026.132499) and [author implementation](https://github.com/kaoyuyukao/SRITrack) specifically address re-entry in sports. The public configuration uses DINOv3 ViT-B/16 on CUDA; its reported benchmark accuracy is not evidence of an acceptable iPhone runtime. It is a further reference for return confirmation, not a dependency selected for this change.

PRTreID's repository carries a Hippocratic license, SoccerNet's game-state code GPL-3.0, and Torchreid MIT. No research repository code or new weights have been bundled in Camelot by this review.

## Actual soccer-clip appearance probe

Offline on the Mac, using a local copy of the user's 33-second soccer stress clip. The existing detector supplied body crops. Compared Apple's Vision image feature prints with OSNet x0.25 pretrained on MSMT17, using each model's preprocessing. Vision used the app's padded ROI; OSNet used 128×256 body crops and ImageNet normalization. This is a small retrieval diagnostic, not a controlled tracker or phone-speed benchmark.

Rank the correct player against every detection on the target frame, using one source-frame reference:

| Reference and target | Vision correct-player rank | OSNet correct-player rank |
| --- | ---: | ---: |
| Blue #9, 0 → 1 s | 1 | 1 |
| Blue #9, 0 → 25 s | 1 | 1 |
| Blue #9, 0 → 26 s | 1 | 2 |
| Blue #9, 0 → 27 s | 1 | 1 |
| Blue #9, 0 → 28 s | 1 | 1 |
| Left foreground white player, 0 → 1 s | 5 | 1 |

At 26 s OSNet ranks blue #3 at 0.8342 above the correct #9 at 0.8315. Vision ranks #9 first but with only a 0.0181 margin over #3. These are cosine similarities, not probabilities. Source frames were visually checked; the local detection indices are not tracking ground truth. Six queries do not establish overall superiority of either model.

Decision: retain the existing on-device feature extractor for this iteration. A soccer-trained, part-aware ReID model remains valuable, but this evidence does not justify swapping to generic OSNet or allowing appearance alone to merge offscreen identities.

Local reproduction artifacts: `/tmp/camelot-player-signatures/probe.py`, `vision-probe.swift`, `detections.json`, `embeddings.npy`, `vision-embeddings.json`, and the numbered source frames. The user's video has not been uploaded or added to the repository.

## Rework selected

- One tracking API and one Track action. Body outlines are optional visual output and never determine identity.
- Retain the initial reference alongside other trusted viewpoints; preserve similarity ordering instead of saturating same-kit candidates with additive bonuses. A trial that forced every view to resemble the first reference was rejected after it reduced coverage on real footage.
- Freeze appearance learning near similar rivals and during contested assignments. Retain the adaptive detector cadence based on combined appearance evidence: a trial that increased frequency on any weak cue reduced distant-player coverage. This is a small adaptation of the evidence-quality principle, not a reproduction of Deep OC-SORT.
- Preserve missing identity in the renderer. New passes hide unresolved positions even if an older effect previously enabled automatic bridging. Explicit estimated display remains a user choice.
- Keep manual selections exact, preserve them during later automatic repairs, and support tap/draw → next source frame, Back, Next, Undo, Done and resuming automatic tracking from the last manual selection.
- Keep saved identity during absence; matching kit alone cannot authorize a long-term return. A future ReID replacement must beat the present approach on held-out soccer clips and physical-device runtime, memory and thermal behavior.

Implementation and verification status are recorded in the follow-up section of `soccer-tracking-review.md` after device tests.
