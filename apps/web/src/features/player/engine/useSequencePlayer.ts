import { useEffect, useMemo, useState } from "react";
import type { CompositionClip } from "@/domain";
import { SequencePlayer, type SequencePlayerState, type SequenceSource } from "./sequence-player";

const EMPTY_STATE: SequencePlayerState = { outputTime: 0, duration: 0, isPlaying: false, isReady: false, error: null, activeClipID: null, activeRecordingID: null, sourceTime: 0 };

/** One player for the lifetime of the component; clips and sources update in place so
 *  selecting or editing events never rebuilds the preview. */
export function useSequencePlayer(clips: readonly CompositionClip[], sources: readonly SequenceSource[]): { player: SequencePlayer; state: SequencePlayerState } {
  const player = useMemo(() => new SequencePlayer(), []);
  const [state, setState] = useState<SequencePlayerState>(EMPTY_STATE);
  useEffect(() => player.subscribe(setState), [player]);
  useEffect(() => () => player.dispose(), [player]);
  const sourceKey = sources.map((s) => `${s.recordingID}:${s.url}`).join("|");
  useEffect(() => { player.setSources(sources); }, [player, sourceKey]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { player.setClips(clips); }, [player, clips]);
  return { player, state };
}
