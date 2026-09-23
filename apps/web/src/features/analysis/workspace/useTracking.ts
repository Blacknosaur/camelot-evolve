import { useCallback, useEffect, useMemo, useRef } from "react";
import type { Rect } from "@/domain/geometry";
import type { UUID } from "@/domain/ids";
import { newId } from "@/domain/ids";
import type { AnalysisAnnotation } from "@/domain/annotation";
import type { PlayerMotion } from "@/domain/tracking";
import { clipAnnotationEnd } from "@/domain/records";
import { boxAt, continuing, correctionTime, prepending } from "@/features/analysis/tracking/motion";
import { cameraTrackingRange, hasFullCameraTrack, playerMatching, sharedCamera } from "@/features/analysis/tracking/library";
import { transformAt } from "@/features/analysis/tracking/motion";
import * as api from "@/features/analysis/tracking/api";
import type { AnalysisEngine, PlayerSample } from "../model/engine";
import { makeStatic, pointsAt } from "../model/annotation";
import type { PlayerEffectOptions } from "../model/player-effects";
import { formatTimecode } from "./format";

/* Background tracking passes from AnalysisOverlayView.swift, driving the engine through the vision
   agent's `tracking/api` contract. One pass runs at a time; cancelling never replaces a saved track. */

export interface TrackingController {
  trackIndependentPlayer(seed: Rect, time: number, effects?: PlayerEffectOptions, from?: number): void;
  beginTracking(id: UUID, seed: Rect, from: number): void;
  beginLinkedTracking(id: UUID, seeds: PlayerSample[], replacing?: number): void;
  trackAllPlayers(): void;
  trackPlayerToEnd(id: UUID): void;
  trackPlayerBackward(id: UUID, thenForward: boolean, time: number): void;
  ensureSharedCameraTracking(force?: boolean, pending?: AnalysisAnnotation | null, bindTime?: number | null): void;
  beginCameraTracking(time: number, fromCurrentFrame?: boolean): void;
  attachOrTrack(id: UUID, seed: Rect, time: number): void;
  cancel(): void;
}

export function useTracking(engine: AnalysisEngine, seek: (time: number) => void, pause: () => void): TrackingController {
  const controller = useRef<AbortController | null>(null);
  useEffect(() => () => controller.current?.abort(), []);

  const run = useCallback(async <T,>(label: string, job: (signal: AbortSignal, report: (fraction: number) => void) => Promise<T>, done: (result: T) => void) => {
    const s = engine.getState();
    if (s.tracking) return;
    controller.current?.abort();
    const abort = new AbortController();
    controller.current = abort;
    pause();
    const id = newId();
    s.setTracking({ id, progress: 0, label });
    try {
      const result = await job(abort.signal, (fraction) => { if (!abort.signal.aborted) engine.getState().setTrackingProgress(fraction); });
      if (!abort.signal.aborted) done(result);
    } catch (error) {
      if (!abort.signal.aborted) engine.getState().setError(error instanceof Error ? error.message : String(error));
    } finally {
      if (engine.getState().tracking?.id === id) engine.getState().setTracking(null);
    }
  }, [engine, pause]);

  return useMemo<TrackingController>(() => {
    const clip = () => engine.getState().clip;
    const player = (id: UUID) => clip().trackingLibrary?.players.find((p) => p.id === id) ?? null;
    const reusablePlayer = (box: Rect, at: number) => {
      const s = engine.getState();
      const saved = s.selectedPlayerTrackID ? player(s.selectedPlayerTrackID) : null;
      const current = saved ? boxAt(saved.motion, at) : null;
      if (saved && current && overlap(current, box) > 0.5) return saved;
      return clip().trackingLibrary ? playerMatching(clip().trackingLibrary!, box, at) : null;
    };

    const controllerValue: TrackingController = {
      trackIndependentPlayer(seed, time, effects, from) {
        const s = engine.getState();
        if (s.placingPlayer && s.correctingTrackID) { s.placePlayer(s.correctingTrackID, seed, time); return; }
        const start = from ?? time, end = clip().endSeconds;
        if (clip().freezeDuration != null || end - start <= 0.05) return;
        const previous = s.correctingTrackID ? player(s.correctingTrackID) : null;
        const trackID = previous?.id ?? newId();
        s.setPicking(false);
        s.setSelectedPlayer({ time: start, box: seed });
        void run("Tracking", (signal, report) => api.trackSelectedPlayer(clip(), seed, start, report, { signal, prior: previous ? { ...previous.motion, identity: previous.identity } : null }), (motion) => {
          const combined: PlayerMotion = { ...(previous ? continuing(previous.motion, motion, start) : motion), trackID };
          const state = engine.getState();
          state.storePlayerTrack(combined);
          state.setSelectedPlayer(state.selectedPlayer, trackID);
          if (effects) state.applyPlayerEffects(effects, new Set(), seed, combined, start);
          if (motion.lostAt != null) {
            seek(correctionTime(motion) ?? motion.lostAt);
            state.setError(`Tracking stopped at ${formatTimecode(motion.lostAt - clip().startSeconds, true)}. Paused at the last tracked frame. Use Fix from this frame to continue.`);
          } else if (!previous && start - clip().startSeconds > 0.1) {
            setTimeout(() => controllerValue.trackPlayerBackward(trackID, false, start), 0);
          }
        });
      },

      beginTracking(id, seed, from) {
        const original = clip().annotations.find((a) => a.id === id);
        if (!original || clip().freezeDuration != null || seed.width <= 0.002 || seed.height <= 0.005 || original.end <= from) return;
        const trackID = original.playerMotion?.trackID ?? newId();
        // Switching an authored animation to follow starts from the pose the user is looking at.
        if (!original.playerMotion) engine.getState().updateLayer(id, (m) => ({ ...m, points: pointsAt(original, from) }), false);
        void run("Tracking", (signal, report) => api.trackSelectedPlayer(clip(), seed, from, report, { signal, prior: original.playerMotion ?? null }), (motion) => {
          const combined: PlayerMotion = { ...(original.playerMotion ? continuing(original.playerMotion, motion, from) : motion), smoothing: original.playerMotion?.smoothing ?? (original.tool === "text" ? 0.95 : undefined), trackID, referenceBox: original.playerMotion?.referenceBox ?? original.playerMotion?.samples[0]?.box ?? seed };
          const state = engine.getState();
          state.updateLayer(id, (m) => { const { cameraMotion: _c, linkedPlayers: _l, ...rest } = m; return { ...rest, playerMotion: combined, keyframes: [] }; }, false);
          state.storePlayerTrack(combined, false);
          state.setSelectedPlayer(state.selectedPlayer, trackID);
          if (motion.lostAt != null) {
            seek(correctionTime(motion) ?? motion.lostAt);
            state.setError(`Tracking stopped at ${formatTimecode(motion.lostAt - clip().startSeconds, true)}. Tap Correct, then select the same player to continue.`);
          }
        });
      },

      beginLinkedTracking(id, seeds, replacing) {
        const original = clip().annotations.find((a) => a.id === id);
        if (!original || seeds.length === 0 || clip().freezeDuration != null) return;
        const initial: PlayerMotion[] = original.linkedPlayers ?? seeds.map((seed) => {
          const saved = clip().trackingLibrary ? playerMatching(clip().trackingLibrary!, seed.box, seed.time) : null;
          const boundSaved = saved ? { ...saved.motion, referenceBox: boxAt(saved.motion, seed.time) ?? seed.box } : null;
          return boundSaved ?? { samples: [seed], trackID: newId(), referenceBox: seed.box };
        });
        engine.getState().checkpoint();
        const end = clip().endSeconds;
        void run("Tracking", async (signal, report) => {
          const motions = initial.map((m) => ({ ...m }));
          let repairFailure: { index: number; time: number } | null = null;
          for (let offset = 0; offset < seeds.length; offset++) {
            if (signal.aborted) throw new DOMException("Aborted", "AbortError");
            const seed = seeds[offset]!, target = replacing ?? offset;
            const old = motions[target];
            if (!old || seed.time >= end) continue;
            if (replacing == null && ((old.samples[old.samples.length - 1]?.time ?? 0) >= end - 0.12 || old.lostAt != null)) continue;
            const trackingSeed = replacing == null && old.samples.length > 1 ? old.samples[old.samples.length - 1]! : seed;
            const motion = await api.trackSelectedPlayer(clip(), trackingSeed.box, trackingSeed.time, (f) => report((offset + f) / seeds.length), { signal, prior: old });
            const failed = correctionTime(motion);
            if (failed != null && failed < (repairFailure?.time ?? Infinity)) repairFailure = { index: target, time: failed };
            motions[target] = { ...continuing(old, motion, trackingSeed.time), trackID: old.trackID ?? newId(), referenceBox: old.referenceBox ?? old.samples[0]?.box };
          }
          return { motions, repairFailure };
        }, ({ motions, repairFailure }) => {
          const state = engine.getState();
          state.updateLayer(id, (m) => { const { playerMotion: _p, cameraMotion: _c, ...rest } = m; return { ...rest, linkedPlayers: motions, keyframes: [] }; }, false);
          for (const motion of motions) state.storePlayerTrack(motion, false);
          const failed = repairFailure ?? (() => { const lost = motions.map((m, i) => ({ i, lost: m.lostAt })).filter((e) => e.lost != null).sort((a, b) => a.lost! - b.lost!)[0]; return lost ? { index: lost.i, time: correctionTime(motions[lost.i]!) ?? lost.lost! } : null; })();
          if (failed) { seek(failed.time); state.setCorrectingPlayer(true, failed.index); }
        });
      },

      trackAllPlayers() {
        const c = clip();
        if (c.freezeDuration != null || c.endSeconds - c.startSeconds <= 0.2) return;
        const state = engine.getState();
        state.setPicking(false); state.setCorrectingPlayer(false); state.select(null, 0);
        void run("Tracking", async (signal, report) => {
          let camera = hasFullCameraTrack(c) ? null : await api.trackCamera(c, cameraTrackingRange(c), (f) => report(f * 0.25), { signal });
          const withCamera = camera ? engine.getState().clip : c;
          const roster = await api.trackRoster(withCamera, (f) => report(camera ? 0.25 + f * 0.75 : f), { signal });
          camera = camera ?? null;
          return { camera, roster };
        }, ({ camera, roster }) => {
          const state = engine.getState();
          state.checkpoint();
          if (camera) state.storeSharedCameraTrack(camera);
          state.setClip(roster.clip, false);
          state.setShowsPlayers(true);
          const lost = roster.clip.trackingLibrary?.players.filter((p) => p.motion.lostAt != null).length ?? 0;
          let summary = roster.tracked === 0 ? "No players could be followed in this clip." : `Followed ${roster.tracked} ${roster.tracked === 1 ? "player" : "players"} (${roster.added} new).`;
          if (lost > 0) summary += ` ${lost} ${lost === 1 ? "track needs" : "tracks need"} correction; use the gap arrows on a selected player to review each section.`;
          state.setError(summary);
        });
      },

      trackPlayerToEnd(id) {
        const saved = player(id);
        const motion = saved?.motion;
        const last = motion ? [...motion.samples].reverse().find((s) => motion.lostAt == null || s.time < motion.lostAt) : undefined;
        if (!saved || !last || last.time >= clip().endSeconds - 0.1 || clip().freezeDuration != null) return;
        const state = engine.getState();
        state.select(null, last.time); state.setSelectedPlayer(null, id); state.setPicking(true, id, false);
        seek(last.time);
        controllerValue.trackIndependentPlayer(last.box, last.time, undefined, last.time);
      },

      trackPlayerBackward(id, thenForward, time) {
        const saved = player(id);
        if (!saved || clip().freezeDuration != null) return;
        const motion: PlayerMotion = { ...saved.motion, identity: saved.identity };
        const current = boxAt(motion, time);
        const nearest = motion.samples.reduce<{ time: number; box: Rect } | null>((best, s) => (!best || Math.abs(s.time - time) < Math.abs(best.time - time) ? s : best), null);
        const seed = current ?? nearest?.box;
        const seedTime = current ? time : nearest?.time ?? time;
        const clipStart = clip().startSeconds, clipEnd = clip().endSeconds;
        if (!seed || (seedTime - clipStart <= 0.1 && !thenForward)) return;
        const state = engine.getState();
        state.select(null, time); state.setSelectedPlayer(null, id); state.setPicking(false);
        void run("Tracking", async (signal, report) => {
          let combined = motion;
          if (seedTime - clipStart > 0.1) {
            const earlier = await api.trackPlayerBackward(clip(), seed, seedTime, (f) => report(thenForward ? f * 0.5 : f), { signal, prior: motion, end: clipStart });
            combined = prepending(combined, earlier, seedTime);
          }
          if (thenForward && clipEnd - seedTime > 0.1) {
            const later = await api.trackSelectedPlayer(clip(), seed, seedTime, (f) => report(0.5 + f * 0.5), { signal, prior: combined });
            combined = continuing(combined, later, seedTime);
          }
          return { ...combined, trackID: id };
        }, (combined) => {
          const s = engine.getState();
          s.storePlayerTrack(combined);
          const box = boxAt(combined, time);
          s.setSelectedPlayer(box ? { time, box } : null, id);
          const first = combined.samples[0]?.time ?? seedTime;
          if (first - clipStart > 0.15) s.setError(`Followed back to ${formatTimecode(first - clipStart, true)}; before that the player could not be recognised. Use Place here or Fix on earlier frames if needed.`);
        });
      },

      ensureSharedCameraTracking(force = false, pending = null, bindTime = null) {
        const c = clip();
        if (c.freezeDuration != null || engine.getState().tracking) return;
        const attach = () => {
          const state = engine.getState();
          const camera = sharedCamera(state.clip.trackingLibrary);
          if (!pending || bindTime == null || !camera || !transformAt(camera, bindTime)) return;
          state.updateLayer(pending.id, (m) => (m.tool === "trajectory" ? { ...pending, trajectoryCameraMotion: camera } : { ...pending, cameraMotion: { ...camera, referenceTime: bindTime } }), false);
        };
        if (!force && hasFullCameraTrack(c)) { if (pending) engine.getState().checkpoint(); attach(); return; }
        engine.getState().checkpoint();
        void run("Camera", (signal, report) => api.trackCamera(c, cameraTrackingRange(c), report, { signal }), (motion) => {
          const state = engine.getState();
          const adopted = state.storeSharedCameraTrack(motion);
          attach();
          if (motion.lostAt != null) {
            seek(motion.samples[motion.samples.length - 1]?.time ?? motion.lostAt);
            state.setError(`Camera motion could not be connected at ${formatTimecode(motion.lostAt - c.startSeconds, true)}. ${adopted ? "The partial track was saved." : "The previous longer track was kept."} Field preview and camera-following layers share this coverage.`);
          }
        });
      },

      beginCameraTracking(time, fromCurrentFrame = true) {
        const s = engine.getState();
        const mark = s.clip.annotations.find((a) => a.id === s.selectedID);
        if (!mark || mark.isLocked === true || s.clip.freezeDuration != null) return;
        const bindTime = mark.cameraMotion?.referenceTime ?? mark.cameraMotion?.samples[0]?.time ?? (fromCurrentFrame ? Math.min(mark.end - 0.05, Math.max(mark.start, time)) : mark.start);
        const pending = mark.tool !== "trajectory" && !mark.cameraMotion ? makeStatic(mark, bindTime) : mark;
        controllerValue.ensureSharedCameraTracking(false, pending, bindTime);
      },

      attachOrTrack(id, seed, time) {
        const saved = reusablePlayer(seed, time);
        const state = engine.getState();
        const mark = state.clip.annotations.find((a) => a.id === id);
        if (saved && mark) {
          const box = boxAt(saved.motion, time);
          state.updateLayer(id, (m) => ({ ...makeStatic(m, time), playerMotion: { ...saved.motion, referenceBox: box ?? saved.motion.samples[0]?.box, smoothing: m.tool === "text" ? 0.95 : saved.motion.smoothing } }), false);
          state.setSelectedPlayer(state.selectedPlayer, saved.id);
        } else controllerValue.beginTracking(id, seed, time);
      },

      cancel() { controller.current?.abort(); engine.getState().setTracking(null); },
    };
    return controllerValue;
  }, [engine, run, seek]);
}

function overlap(a: Rect, b: Rect): number {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  const w = Math.min(a.x + a.width, b.x + b.width) - x, h = Math.min(a.y + a.height, b.y + b.height) - y;
  if (w <= 0 || h <= 0) return 0;
  const inter = w * h;
  return inter / Math.max(1e-9, a.width * a.height + b.width * b.height - inter);
}

export { clipAnnotationEnd };
