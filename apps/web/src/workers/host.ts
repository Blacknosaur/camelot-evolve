import type { JobName, WorkerJobs, WorkerRequest, WorkerResponse } from "./protocol";

export interface JobContext<K extends JobName> {
  signal: AbortSignal;
  progress(p: WorkerJobs[K]["progress"]): void;
}

export type JobHandler<K extends JobName> = (input: WorkerJobs[K]["input"], context: JobContext<K>) => Promise<WorkerJobs[K]["output"]>;

/** Call once inside a worker module with the jobs it implements. */
export function serveJobs(handlers: { [K in JobName]?: JobHandler<K> }) {
  const controllers = new Map<number, AbortController>();
  const post = (message: WorkerResponse, transfer: Transferable[] = []) => (self as unknown as Worker).postMessage(message, transfer);
  self.onmessage = async (event: MessageEvent<WorkerRequest>) => {
    const request = event.data;
    if ("cancel" in request) { controllers.get(request.id)?.abort(); return; }
    const handler = handlers[request.job] as JobHandler<JobName> | undefined;
    if (!handler) { post({ id: request.id, kind: "error", message: `No handler for ${request.job}` }); return; }
    const controller = new AbortController();
    controllers.set(request.id, controller);
    try {
      const output = await handler(request.input, { signal: controller.signal, progress: (progress) => post({ id: request.id, kind: "progress", progress }) });
      if (!controller.signal.aborted) post({ id: request.id, kind: "result", output });
    } catch (error) {
      if (!controller.signal.aborted) post({ id: request.id, kind: "error", message: error instanceof Error ? error.message : String(error) });
    } finally { controllers.delete(request.id); }
  };
}
