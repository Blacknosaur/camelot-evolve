/* Clip-owned tracking library operations: port of AnalysisTrackingLibrary.swift (`AnalysisTrackingLibrary`
   and the `CompositionClip` extension). Every function is pure: it returns a new clip/library. */
import type { Rect } from "@/domain/geometry";
import type { UUID } from "@/domain/ids";
import { newId as newUUID } from "@/domain/ids";
import type { AnalysisAnnotation } from "@/domain/annotation";
import { GROUNDABLE_TOOLS } from "@/domain/annotation";
import type { CompositionClip } from "@/domain/records";
import type { AnalysisTrackingLibrary, AnalysisTrackingLibraryPlayer, AnnotationCameraMotion, PlayerIdentityMemory, PlayerMotion, TimeRange } from "@/domain/tracking";
import { emptyTrackingLibrary } from "@/domain/tracking";
import { confirmedNumber } from "./identity";
import { overlap, rectMaxY, rectMidX } from "./geometry";
import { bound, boxAt, bridged, coveredDuration, covers, placeSample, referenceBox, transformAt } from "./motion";

export const playerNumber = (p: AnalysisTrackingLibraryPlayer) => (p.identity ? confirmedNumber(p.identity.number) : null);
export function playerKitColor(p: AnalysisTrackingLibraryPlayer): { red: number; green: number; blue: number } | null {
  const c = p.identity?.kitColor;
  return c && c.length === 3 ? { red: c[0]!, green: c[1]!, blue: c[2]! } : null;
}

/** The clip-wide camera track offered to new effects. */
export function sharedCamera(library: AnalysisTrackingLibrary | undefined | null): AnnotationCameraMotion | null {
  if (!library) return null;
  if (library.sharedCameraID) { const camera = library.cameras.find((c) => c.trackID === library.sharedCameraID); if (camera) return camera; }
  let best: AnnotationCameraMotion | null = null;
  for (const camera of library.cameras) if (!best || coveredDuration(camera) > coveredDuration(best)) best = camera;
  return best;
}

export function cameraAt(library: AnalysisTrackingLibrary | undefined | null, time: number): AnnotationCameraMotion | null {
  const camera = sharedCamera(library);
  return camera && transformAt(camera, time) ? camera : null;
}

/** The saved player whose track clearly overlaps `box` at `time`. */
export function playerMatching(library: AnalysisTrackingLibrary, box: Rect, time: number): AnalysisTrackingLibraryPlayer | null {
  const candidates = library.players.flatMap((track) => {
    const tracked = boxAt(track.motion, time);
    if (!tracked) return [];
    const o = overlap(tracked, box);
    return o > 0.55 ? [[track, o] as const] : [];
  }).sort((a, b) => b[1] - a[1]);
  const best = candidates[0];
  if (!best || (candidates.length > 1 && !(best[1] > candidates[1]![1] * 1.4))) return null;
  return best[0];
}

// MARK: - Clip mutations (return new clips)

/** Stores a source track and refreshes every drawing that follows it. */
export function storePlayerTrack(clip: CompositionClip, motion: PlayerMotion, identity?: PlayerIdentityMemory): CompositionClip {
  const id = motion.trackID;
  if (!id) return clip;
  const library: AnalysisTrackingLibrary = clip.trackingLibrary ? { ...clip.trackingLibrary, players: clip.trackingLibrary.players.slice() } : emptyTrackingLibrary();
  const learned = identity ?? motion.identity;
  let source: PlayerMotion = { ...motion, referenceBox: undefined, smoothing: undefined, identity: undefined };
  source = bridged(source, sharedCamera(library));
  const index = library.players.findIndex((p) => p.id === id);
  if (index >= 0) library.players[index] = { ...library.players[index]!, motion: source, identity: learned ?? library.players[index]!.identity };
  else library.players.push({ id, name: `Player ${library.players.length + 1}`, motion: source, identity: learned });
  const refreshed = (old: PlayerMotion): PlayerMotion => old.trackID === id ? { ...source, referenceBox: referenceBox(old), smoothing: old.smoothing, gapBridging: old.gapBridging ?? source.gapBridging } : old;
  const annotations = clip.annotations.map((mark) => ({
    ...mark,
    playerMotion: mark.playerMotion ? refreshed(mark.playerMotion) : mark.playerMotion,
    linkedPlayers: mark.linkedPlayers ? mark.linkedPlayers.map(refreshed) : mark.linkedPlayers,
  }));
  return { ...clip, trackingLibrary: library, annotations };
}

export function storeCameraTrack(clip: CompositionClip, motion: AnnotationCameraMotion): CompositionClip {
  const id = motion.trackID;
  if (!id) return clip;
  const library: AnalysisTrackingLibrary = clip.trackingLibrary ? { ...clip.trackingLibrary, cameras: clip.trackingLibrary.cameras.slice() } : emptyTrackingLibrary();
  const source: AnnotationCameraMotion = { ...motion, referenceTime: undefined };
  const index = library.cameras.findIndex((c) => c.trackID === id);
  if (index >= 0) library.cameras[index] = source; else library.cameras.push(source);
  const annotations = clip.annotations.map((mark) => ({
    ...mark,
    cameraMotion: mark.cameraMotion?.trackID === id ? { ...source, referenceTime: mark.cameraMotion.referenceTime } : mark.cameraMotion,
    trajectoryCameraMotion: mark.trajectoryCameraMotion?.trackID === id ? source : mark.trajectoryCameraMotion,
  }));
  const groundCalibration = clip.groundCalibration?.cameraMotion?.trackID === id ? { ...clip.groundCalibration, cameraMotion: source } : clip.groundCalibration;
  return { ...clip, trackingLibrary: library, annotations, groundCalibration };
}

/** Source frames referenced by saved geometry must stay inside the camera pass. */
export function cameraTrackingRange(clip: CompositionClip): TimeRange {
  const references = clip.annotations.flatMap((a) => {
    const value = a.cameraMotion?.referenceTime ?? a.cameraMotion?.samples[0]?.time ?? a.groundReferenceTime;
    return value == null ? [] : [value];
  });
  if (clip.groundCalibration && !clip.groundCalibration.fixedCamera) references.push(clip.groundCalibration.referenceTime);
  const finite = references.filter((r) => Number.isFinite(r) && r >= 0);
  return [Math.min(clip.startSeconds, finite.length ? Math.min(...finite) : clip.startSeconds), Math.max(clip.endSeconds, finite.length ? Math.max(...finite) : clip.endSeconds)];
}

export function hasFullCameraTrack(clip: CompositionClip): boolean {
  const camera = sharedCamera(clip.trackingLibrary);
  return camera != null && covers(camera, cameraTrackingRange(clip));
}

/** A failed rerun cannot erase a longer usable pass. Returns null when the new pass was rejected. */
export function storeSharedCameraTrack(clip: CompositionClip, motion: AnnotationCameraMotion): CompositionClip | null {
  const old = sharedCamera(clip.trackingLibrary);
  if (old && !covers(motion, cameraTrackingRange(clip)) && coveredDuration(old) > coveredDuration(motion)) return null;
  const source: AnnotationCameraMotion = { ...motion, trackID: motion.trackID ?? newUUID(), referenceTime: undefined };
  let next = storeCameraTrack(clip, source);
  next = { ...next, trackingLibrary: { ...next.trackingLibrary!, sharedCameraID: source.trackID } };
  next = refreshSharedCameraBindings(next);
  return rebridgePlayerTracks(next);
}

/** Bridged positions depend on the clip camera; rebuild them for every saved player. */
export function rebridgePlayerTracks(clip: CompositionClip): CompositionClip {
  let next = clip;
  for (const player of clip.trackingLibrary?.players ?? []) next = storePlayerTrack(next, { ...player.motion, trackID: player.id });
  return next;
}

export function refreshSharedCameraBindings(clip: CompositionClip): CompositionClip {
  const shared = sharedCamera(clip.trackingLibrary);
  if (!shared) return clip;
  let groundCalibration = clip.groundCalibration;
  if (groundCalibration && !groundCalibration.fixedCamera && transformAt(shared, groundCalibration.referenceTime)) groundCalibration = { ...groundCalibration, cameraMotion: shared };
  const annotations = clip.annotations.map((mark) => {
    let next = mark;
    if (next.cameraMotion) {
      const reference = next.cameraMotion.referenceTime ?? next.cameraMotion.samples[0]?.time ?? next.start;
      if (transformAt(shared, reference)) next = { ...next, cameraMotion: { ...shared, referenceTime: reference } };
    }
    if (!next.cameraMotion && next.grounded === true && GROUNDABLE_TOOLS.includes(next.tool) && next.fieldLines !== true && !next.playerMotion && !next.linkedPlayers &&
      next.keyframes.length === 0 && clip.groundCalibration?.fixedCamera === false) {
      const reference = next.groundReferenceTime ?? next.start;
      if (transformAt(shared, reference)) next = { ...next, cameraMotion: { ...shared, referenceTime: reference } };
    }
    if (next.trajectoryCameraMotion) next = { ...next, trajectoryCameraMotion: shared };
    return next;
  });
  return { ...clip, annotations, groundCalibration };
}

/** Promote legacy baked tracks once, without running vision again. */
export function importAnnotationTracks(clip: CompositionClip): CompositionClip {
  let next: CompositionClip = { ...clip, annotations: clip.annotations.map((a) => ({ ...a })) };
  for (let index = 0; index < next.annotations.length; index++) {
    const mark = next.annotations[index]!;
    if (mark.playerMotion && !mark.playerMotion.trackID) {
      const motion = { ...mark.playerMotion, trackID: mark.id };
      next.annotations[index] = { ...mark, playerMotion: motion };
      next = storePlayerTrack(next, motion);
    }
    const links = next.annotations[index]!.linkedPlayers;
    if (links) {
      const updated = links.slice();
      for (let anchor = 0; anchor < updated.length; anchor++) {
        if (updated[anchor]!.trackID) continue;
        const motion = { ...updated[anchor]!, trackID: newUUID() };
        updated[anchor] = motion;
        next.annotations[index] = { ...next.annotations[index]!, linkedPlayers: updated };
        next = storePlayerTrack(next, motion);
      }
    }
    const current = next.annotations[index]!;
    if (current.cameraMotion) {
      const motion = { ...current.cameraMotion, trackID: current.cameraMotion.trackID ?? current.id };
      next.annotations[index] = { ...current, cameraMotion: motion };
      if (!next.trackingLibrary?.cameras.some((c) => c.trackID === motion.trackID)) next = storeCameraTrack(next, motion);
    }
    const after = next.annotations[index]!;
    if (after.trajectoryCameraMotion) {
      const motion = { ...after.trajectoryCameraMotion, trackID: after.trajectoryCameraMotion.trackID ?? after.id };
      next.annotations[index] = { ...after, trajectoryCameraMotion: motion };
      if (!next.trackingLibrary?.cameras.some((c) => c.trackID === motion.trackID)) next = storeCameraTrack(next, motion);
    }
  }
  if (next.groundCalibration?.cameraMotion) {
    const camera = { ...next.groundCalibration.cameraMotion, trackID: next.groundCalibration.cameraMotion.trackID ?? next.id };
    next = { ...next, groundCalibration: { ...next.groundCalibration, cameraMotion: camera } };
    if (!next.trackingLibrary?.cameras.some((c) => c.trackID === camera.trackID)) next = storeCameraTrack(next, camera);
  }
  return refreshSharedCameraBindings(next);
}

export interface RosterMergeEntry { id: UUID; motion: PlayerMotion; memory: PlayerIdentityMemory; isNew: boolean }

/** Fold a roster pass into the saved players. */
export function mergeRoster(clip: CompositionClip, entries: readonly RosterMergeEntry[]): { clip: CompositionClip; tracked: number; added: number } {
  let next = clip, tracked = 0, added = 0;
  for (const entry of entries) {
    let motion: PlayerMotion = { ...entry.motion, trackID: entry.id };
    const existing = next.trackingLibrary?.players.find((p) => p.id === entry.id);
    if (existing) {
      if (motion.samples.length * 2 < existing.motion.samples.length) {
        const players = next.trackingLibrary!.players.map((p) => (p.id === entry.id ? { ...p, identity: entry.memory } : p));
        next = { ...next, trackingLibrary: { ...next.trackingLibrary!, players } };
        continue;
      }
      motion = { ...motion, gapBridging: existing.motion.gapBridging ?? motion.gapBridging };
    } else added += 1;
    tracked += 1;
    next = storePlayerTrack(next, motion, entry.memory);
  }
  return { clip: next, tracked, added };
}

/** Hand-place a saved player where tracking never confirmed it. */
export function placePlayerSample(clip: CompositionClip, trackID: UUID, box: Rect, time: number): CompositionClip | null {
  const player = clip.trackingLibrary?.players.find((p) => p.id === trackID);
  if (!player) return null;
  return storePlayerTrack(clip, placeSample({ ...player.motion, trackID }, box, time));
}

export const canRemovePlayerTrack = (clip: CompositionClip, id: UUID) =>
  !clip.annotations.some((mark) => mark.playerMotion?.trackID === id || mark.linkedPlayers?.some((l) => l.trackID === id));

export function removePlayerTrack(clip: CompositionClip, id: UUID): CompositionClip | null {
  if (!canRemovePlayerTrack(clip, id) || !clip.trackingLibrary) return null;
  return { ...clip, trackingLibrary: { ...clip.trackingLibrary, players: clip.trackingLibrary.players.filter((p) => p.id !== id) } };
}

/** Per-drawing limit on how long an effect follows a bridged position. */
export function setGapBridging(clip: CompositionClip, seconds: number, layerID: UUID): CompositionClip {
  return {
    ...clip,
    annotations: clip.annotations.map((mark) => {
      if (mark.id !== layerID || mark.isLocked === true) return mark;
      return {
        ...mark,
        playerMotion: mark.playerMotion ? { ...mark.playerMotion, gapBridging: seconds } : mark.playerMotion,
        linkedPlayers: mark.linkedPlayers?.map((m) => ({ ...m, gapBridging: seconds })),
      };
    }),
  };
}

/** Rebind one layer to a saved player without touching either source track. `makeStatic` bakes the layer's
    authored geometry at `time` (owned by the analysis model); pass the identity when the layer has no motion. */
export function followSavedPlayer(clip: CompositionClip, player: AnalysisTrackingLibraryPlayer, layerID: UUID, time: number,
  makeStatic: (mark: AnalysisAnnotation, time: number) => AnalysisAnnotation = (mark) => mark): CompositionClip | null {
  const index = clip.annotations.findIndex((a) => a.id === layerID);
  const original = clip.annotations[index];
  if (!original || original.isLocked === true || original.linkedPlayers) return null;
  const smoothing = original.playerMotion?.smoothing ?? (original.tool === "text" ? 0.95 : undefined);
  const boundMotion = bound(player.motion, time, smoothing);
  const box = boundMotion ? referenceBox(boundMotion) : undefined;
  if (!boundMotion || !box) return null;
  const oldBox = original.playerMotion ? boxAt(original.playerMotion, time) ?? referenceBox(original.playerMotion) : undefined;
  let mark = makeStatic(original, time);
  if (oldBox) mark = { ...mark, points: mark.points.map((p) => ({ x: p.x + rectMidX(box) - rectMidX(oldBox), y: p.y + rectMaxY(box) - rectMaxY(oldBox) })) };
  mark = { ...mark, playerMotion: { ...boundMotion, trackID: player.id, smoothing }, playerEffectGroupID: newUUID() };
  const annotations = clip.annotations.slice();
  annotations[index] = mark;
  return { ...clip, annotations };
}
