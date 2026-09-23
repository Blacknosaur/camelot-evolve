import { useEffect, useState } from "react";

/* Tiny change bus so screens re-query IndexedDB after any write. The repository publishes the
   store name it touched; `useLiveQuery` re-runs when a dependency store changes. */

export type LiveStore = "projects" | "events" | "recordings" | "compositions" | "media";
type Listener = (store: LiveStore) => void;
const listeners = new Set<Listener>();

export function publishChange(store: LiveStore) { for (const listener of listeners) listener(store); }

export function subscribeChanges(listener: Listener): () => void { listeners.add(listener); return () => { listeners.delete(listener); }; }

export interface LiveResult<T> { data: T | undefined; isLoading: boolean; error: Error | null; refresh(): void }

/** Runs `query` on mount, whenever `deps` change, and whenever one of `stores` is written. */
export function useLiveQuery<T>(query: () => Promise<T>, stores: readonly LiveStore[], deps: readonly unknown[] = []): LiveResult<T> {
  const [state, setState] = useState<{ data: T | undefined; isLoading: boolean; error: Error | null }>({ data: undefined, isLoading: true, error: null });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let cancelled = false;
    query().then((data) => { if (!cancelled) setState({ data, isLoading: false, error: null }); }, (error: unknown) => { if (!cancelled) setState((s) => ({ ...s, isLoading: false, error: error instanceof Error ? error : new Error(String(error)) })); });
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tick, ...deps]);
  useEffect(() => subscribeChanges((store) => { if (stores.includes(store)) setTick((t) => t + 1); }), [stores.join(",")]); // eslint-disable-line react-hooks/exhaustive-deps
  return { ...state, refresh: () => setTick((t) => t + 1) };
}
