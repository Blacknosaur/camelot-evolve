import type { JobName, WorkerJobs, WorkerRequest, WorkerResponse } from "./protocol";

export interface JobHandle<K extends JobName> {
  result: Promise<WorkerJobs[K]["output"]>;
  cancel(): void;
}

/** Wraps a Worker with typed job dispatch, progress callbacks and cancellation. */
export class WorkerClient {
  private nextId = 1;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; onProgress?: (p: unknown) => void }>();

  constructor(private readonly worker: Worker) {
    worker.onmessage = (event: MessageEvent<WorkerResponse>) => {
      const entry = this.pending.get(event.data.id);
      if (!entry) return;
      if (event.data.kind === "progress") entry.onProgress?.(event.data.progress);
      else if (event.data.kind === "result") { this.pending.delete(event.data.id); entry.resolve(event.data.output); }
      else { this.pending.delete(event.data.id); entry.reject(new Error(event.data.message)); }
    };
    worker.onerror = (event) => { for (const entry of this.pending.values()) entry.reject(new Error(event.message)); this.pending.clear(); };
  }

  run<K extends JobName>(job: K, input: WorkerJobs[K]["input"], onProgress?: (p: WorkerJobs[K]["progress"]) => void, transfer: Transferable[] = []): JobHandle<K> {
    const id = this.nextId++;
    const result = new Promise<WorkerJobs[K]["output"]>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject, onProgress: onProgress as ((p: unknown) => void) | undefined });
      const request: WorkerRequest<K> = { id, job, input };
      this.worker.postMessage(request, transfer);
    });
    return { result, cancel: () => { this.worker.postMessage({ id, cancel: true } satisfies WorkerRequest); const entry = this.pending.get(id); this.pending.delete(id); entry?.reject(new DOMException("Cancelled", "AbortError")); } };
  }

  terminate() { this.worker.terminate(); this.pending.clear(); }
}
