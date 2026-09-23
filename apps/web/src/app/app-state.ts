import { create } from "zustand";
import { createJSONStorage, persist } from "zustand/middleware";
import { createAPIClient, errorMessage, type OrganizationResponse } from "./api-client";

/* Port of AppState.swift: session, organization, connection and sync status.
   OWNER: library agent (onboarding/account). The full sync engine (push/pull/uploads) is
   a later step; `sync()` already reports status the way the iOS app does so screens are final. */

export type ConnectionState = "checking" | "online" | "offline";

export interface AppState {
  isAuthenticated: boolean;
  /** True when the user chose to work offline without an account. */
  isOfflineWorkspace: boolean;
  userName: string;
  email: string | null;
  organizationID: string | null;
  organizationName: string | null;
  apiBaseURL: string;
  /** Stable per-browser identifier sent with sync pushes. */
  deviceID: string;
  connectionState: ConnectionState;
  connectionIssue: string | null;
  isWorking: boolean;
  /** Last authentication failure shown on the onboarding form. */
  errorMessage: string | null;
  syncMessage: string | null;
  /** Set by the camera while recording; sync pauses. */
  isCapturing: boolean;

  continueOffline(name?: string): void;
  signIn(session: { userName: string; email: string; organizationID: string | null; organizationName: string | null }): void;
  signOut(): void;
  setConnection(state: ConnectionState, issue?: string | null): void;
  setWorking(isWorking: boolean, message?: string | null): void;
  setCapturing(isCapturing: boolean): void;
  setAPIBaseURL(url: string): void;

  checkConnection(): Promise<void>;
  createAccount(input: { name: string; email: string; password: string; organization: string }): Promise<void>;
  signInWithPassword(input: { email: string; password: string }): Promise<void>;
  /** Mirrors `AppState.sync`: guarded by isWorking/isCapturing/organizationID, reports a status message. */
  sync(): Promise<void>;
}

// Same-origin by default: the Vite dev server proxies /api to the Hono API (see vite.config.ts).
const defaultAPI = "";

export const api = () => createAPIClient(useAppState.getState().apiBaseURL);

export const useAppState = create<AppState>()(
  persist(
    (set, get) => ({
      isAuthenticated: false,
      isOfflineWorkspace: false,
      userName: "Coach",
      email: null,
      organizationID: null,
      organizationName: null,
      apiBaseURL: defaultAPI,
      deviceID: crypto.randomUUID().toUpperCase(),
      connectionState: "checking",
      connectionIssue: null,
      isWorking: false,
      errorMessage: null,
      syncMessage: null,
      isCapturing: false,

      continueOffline: (name) => set({ isAuthenticated: true, isOfflineWorkspace: true, userName: name?.trim() || "Coach", organizationID: null, organizationName: null, connectionState: "offline" }),
      signIn: (session) => set({ ...session, isAuthenticated: true, isOfflineWorkspace: false, errorMessage: null }),
      signOut: () => {
        const { isOfflineWorkspace, apiBaseURL } = get();
        if (!isOfflineWorkspace) createAPIClient(apiBaseURL).signOut().catch(() => { /* local sign-out always succeeds */ });
        set({ isAuthenticated: false, isOfflineWorkspace: false, email: null, organizationID: null, organizationName: null, userName: "Coach", syncMessage: null, errorMessage: null });
      },
      setConnection: (connectionState, issue = null) => set({ connectionState, connectionIssue: issue }),
      setWorking: (isWorking, message) => set({ isWorking, ...(message !== undefined ? { syncMessage: message } : {}) }),
      setCapturing: (isCapturing) => set({ isCapturing }),
      setAPIBaseURL: (apiBaseURL) => set({ apiBaseURL }),

      checkConnection: async () => {
        set({ connectionState: "checking", connectionIssue: null });
        try {
          await api().health();
          set({ connectionState: "online", connectionIssue: null });
        } catch (error) {
          set({ connectionState: "offline", connectionIssue: errorMessage(error) });
        }
      },

      createAccount: ({ name, email, password, organization }) => authenticate(set, async () => {
        const client = api();
        await client.signUp(name, email, password);
        const org = await client.createOrganization(organization);
        persistSession(set, name, email, org);
      }),

      signInWithPassword: ({ email, password }) => authenticate(set, async () => {
        const client = api();
        await client.signIn(email, password);
        const organizations = await client.listOrganizations().catch(() => [] as OrganizationResponse[]);
        persistSession(set, email, email, organizations[0] ?? null);
      }),

      sync: async () => {
        const state = get();
        if (state.isWorking) return;
        if (state.isCapturing) { set({ syncMessage: "Sync paused while recording." }); return; }
        if (!state.organizationID) { set({ syncMessage: "Create or join an organization to sync. Your work remains saved locally." }); return; }
        set({ isWorking: true });
        try {
          // TODO(sync agent): push the outbox, pull remote changes and upload media here.
          await api().health();
          set({ connectionState: "online", connectionIssue: null, syncMessage: "Synced successfully." });
        } catch (error) {
          const message = errorMessage(error);
          set({ connectionState: "offline", connectionIssue: message, syncMessage: message });
        } finally { set({ isWorking: false }); }
      },
    }),
    {
      name: "camelot.app-state",
      storage: createJSONStorage(safeStorage),
      partialize: (s) => ({ isAuthenticated: s.isAuthenticated, isOfflineWorkspace: s.isOfflineWorkspace, userName: s.userName, email: s.email, organizationID: s.organizationID, organizationName: s.organizationName, apiBaseURL: s.apiBaseURL, deviceID: s.deviceID }),
    },
  ),
);

/** localStorage when available; an in-memory stand-in in private windows and test runners. */
function safeStorage(): Storage {
  try { if (typeof localStorage !== "undefined" && localStorage) return localStorage; } catch { /* blocked */ }
  const memory = new Map<string, string>();
  return { get length() { return memory.size; }, clear: () => memory.clear(), getItem: (k) => memory.get(k) ?? null, key: (i) => [...memory.keys()][i] ?? null, removeItem: (k) => { memory.delete(k); }, setItem: (k, v) => { memory.set(k, v); } };
}

type Set = (partial: Partial<AppState>) => void;

async function authenticate(set: Set, work: () => Promise<void>) {
  set({ isWorking: true, errorMessage: null });
  try {
    await work();
    set({ connectionState: "online", connectionIssue: null });
  } catch (error) {
    const message = errorMessage(error);
    set({ errorMessage: message, connectionState: "offline", connectionIssue: message });
  } finally { set({ isWorking: false }); }
}

function persistSession(set: Set, name: string, email: string, organization: OrganizationResponse | null) {
  set({ userName: name, email, organizationID: organization?.id ?? null, organizationName: organization?.name ?? null, isAuthenticated: true, isOfflineWorkspace: false });
}
