/* Port of APIClient.swift. Talks to the Hono API (apps/api): Better Auth email+password,
   the organization plugin, health, sync push/pull, chunked uploads and share links.
   Sessions are cookie based, so every request sends credentials. */

export class APIError extends Error {
  constructor(message: string, readonly status?: number) { super(message); this.name = "APIError"; }
}

export interface OrganizationResponse { id: string; name: string }
export interface SyncMutation {
  mutationId: string;
  entityId: string;
  entityType: string;
  operation: "upsert" | "delete";
  baseVersion: number | null;
  parentId: string | null;
  payload: Record<string, unknown>;
  clientTimestamp: string;
}
export interface MutationResult { mutationId: string; status: string; version?: number | null; serverVersion?: number | null }
export interface PushResponse { results: MutationResult[] }
export interface RemoteChange { entityType: string; entityId: string; version: number; operation: string; parentId: string | null; payload: Record<string, string> }
export interface PullResponse { changes: RemoteChange[]; cursor: string; hasMore: boolean }
export interface UploadSession { uploadId: string; chunkSize: number; totalParts: number; receivedParts: number[]; status: string }

const REQUEST_TIMEOUT_MS = 10_000;

/** Slug for a new organization, matching the iOS client ("FC Rovers" → "fc-rovers-a1b2c3"). */
export function organizationSlug(name: string, suffix = crypto.randomUUID().slice(0, 6).toLowerCase()): string {
  const base = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return `${base}-${suffix}`;
}

export function createAPIClient(baseURL: string) {
  const host = (() => { try { return new URL(baseURL || location.origin).host; } catch { return "server"; } })();

  async function request<T>(path: string, init: { method?: string; body?: unknown; timeoutMs?: number } = {}): Promise<T> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), init.timeoutMs ?? REQUEST_TIMEOUT_MS);
    let response: Response;
    try {
      response = await fetch(`${baseURL}${path}`, {
        method: init.method ?? "GET",
        headers: { "Content-Type": "application/json" },
        body: init.body === undefined ? undefined : JSON.stringify(init.body),
        credentials: "include",
        signal: controller.signal,
      });
    } catch {
      throw new APIError(`Cannot reach ${host}. Check your connection and that the API is running.`);
    } finally { clearTimeout(timer); }
    const text = await response.text();
    const json = text ? safeJSON(text) : null;
    if (!response.ok) {
      const message = (json as { message?: string; error?: string } | null)?.message ?? (json as { error?: string } | null)?.error;
      throw new APIError(message ?? `Server returned HTTP ${response.status}`, response.status);
    }
    return json as T;
  }

  return {
    baseURL,
    health: () => request<{ status: string }>("/api/health"),
    signUp: (name: string, email: string, password: string) => request<unknown>("/api/auth/sign-up/email", { method: "POST", body: { name, email, password } }),
    signIn: (email: string, password: string) => request<unknown>("/api/auth/sign-in/email", { method: "POST", body: { email, password } }),
    signOut: () => request<unknown>("/api/auth/sign-out", { method: "POST", body: {} }),
    listOrganizations: () => request<OrganizationResponse[]>("/api/auth/organization/list"),
    createOrganization: (name: string) => request<OrganizationResponse>("/api/auth/organization/create", { method: "POST", body: { name, slug: organizationSlug(name) } }),
    push: (organizationId: string, deviceId: string, mutations: SyncMutation[]) => request<PushResponse>("/api/sync/push", { method: "POST", body: { organizationId, deviceId, mutations } }),
    pull: (organizationId: string, cursor: string) => request<PullResponse>(`/api/sync/pull?organizationId=${encodeURIComponent(organizationId)}&cursor=${cursor}&limit=200`),
    createShare: async (organizationId: string, mediaId: string) => {
      const share = await request<{ token: string; url: string }>("/api/shares", { method: "POST", body: { organizationId, mediaId } });
      if (!share.url) throw new APIError("Server returned an invalid share URL.");
      return share.url;
    },

    /** Chunked, resumable upload mirroring `uploadVideo` on iOS. Returns the number of bytes uploaded. */
    async uploadVideo(organizationId: string, mediaId: string, file: File, options: { revision?: string; onProgress?: (bytes: number) => void; shouldContinue?: () => boolean } = {}): Promise<number> {
      if (file.size <= 0) throw new APIError("Recording file is empty or missing.");
      const extension = file.name.split(".").pop() ?? "mp4";
      const upload = await request<UploadSession>("/api/uploads", {
        method: "POST",
        body: { organizationId, mediaId, fileName: options.revision ? `${mediaId}-${options.revision}.${extension}` : file.name, contentType: file.type || (extension === "mp4" ? "video/mp4" : "video/quicktime"), totalBytes: file.size },
      });
      if (upload.status === "complete") return file.size;
      const received = new Set(upload.receivedParts);
      let uploaded = 0;
      for (let part = 1; part <= upload.totalParts; part += 1) {
        if (options.shouldContinue && !options.shouldContinue()) throw new APIError("Upload paused while recording.");
        const offset = (part - 1) * upload.chunkSize;
        const chunk = file.slice(offset, Math.min(offset + upload.chunkSize, file.size));
        if (received.has(part)) { uploaded += chunk.size; options.onProgress?.(uploaded); continue; }
        const bytes = await chunk.arrayBuffer();
        const digest = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (b) => b.toString(16).padStart(2, "0")).join("");
        await uploadPart(upload.uploadId, part, bytes, digest);
        uploaded += bytes.byteLength;
        options.onProgress?.(uploaded);
      }
      await request<unknown>(`/api/uploads/${upload.uploadId}/complete`, { method: "POST", body: {} });
      return uploaded;
    },
  };

  async function uploadPart(uploadId: string, part: number, bytes: ArrayBuffer, checksum: string) {
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      try {
        const response = await fetch(`${baseURL}/api/uploads/${uploadId}/parts/${part}`, { method: "PUT", body: bytes, credentials: "include", headers: { "Content-Type": "application/octet-stream", "x-chunk-sha256": checksum } });
        if (response.ok) return;
        if (response.status < 500) throw new APIError(`Could not upload recording part ${part} (HTTP ${response.status}).`, response.status);
      } catch (error) {
        if (error instanceof APIError) throw error;
      }
      if (attempt < 3) await new Promise((resolve) => setTimeout(resolve, attempt * 1000));
    }
    throw new APIError("Upload paused. It will resume when the server is reachable.");
  }
}

export type APIClient = ReturnType<typeof createAPIClient>;

function safeJSON(text: string): unknown { try { return JSON.parse(text); } catch { return null; } }

export const errorMessage = (error: unknown) => (error instanceof Error ? error.message : String(error));
