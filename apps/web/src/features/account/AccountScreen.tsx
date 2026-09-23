import { useCallback, useEffect, useState } from "react";
import { useAppState } from "@/app/app-state";
import { APPEARANCES, useAppearance, type Appearance } from "@/app/appearance";
import { mediaStore } from "@/storage/media-store";
import { byteCount } from "@/design/format";
import { ListGroup, ListRow, ScreenHeader, SegmentedControl, Spinner } from "@/design/components";
import { Icon } from "@/design/icons";
import { ConfirmDialog } from "@/design/sheet";
import { ConnectionBadge } from "@/features/onboarding/OnboardingScreen";
import { SIGN_OUT_MESSAGE, STORAGE_FOOTER, initials, syncFooter, syncStatusText } from "./account-logic";
import "./AccountScreen.css";

interface StorageUsage { recordings: number; exports: number; cache: number }

async function measureStorage(): Promise<StorageUsage> {
  const store = await mediaStore();
  const size = (folder: "Recordings" | "Exports" | "Thumbnails") => store.size(folder).catch(() => 0);
  const [recordings, exports, cache] = await Promise.all([size("Recordings"), size("Exports"), size("Thumbnails")]);
  return { recordings, exports, cache };
}

const APPEARANCE_ICONS: Record<Appearance, React.ReactElement> = { system: <Icon.HalfCircle />, light: <Icon.Sun />, dark: <Icon.Moon /> };

/** Port of SettingsView: profile, appearance, sync, on-device storage and sign out. */
export default function AccountScreen() {
  const state = useAppState();
  const [appearance, setAppearance] = useAppearance();
  const [storage, setStorage] = useState<StorageUsage | null>(null);
  const [confirmingSignOut, setConfirmingSignOut] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const refresh = useCallback(async () => {
    setRefreshing(true);
    try {
      await Promise.all([state.checkConnection(), measureStorage().then(setStorage)]);
    } finally { setRefreshing(false); }
  }, [state.checkConnection]);

  useEffect(() => { void measureStorage().then(setStorage); }, []);

  return (
    <div className="ac">
      <ScreenHeader title="Account" actions={<button type="button" className="ds-menu-trigger" aria-label="Refresh" title="Refresh" onClick={() => void refresh()} disabled={refreshing}>{refreshing ? <Spinner size={18} /> : <Icon.Refresh />}</button>} />
      <div className="ac-body">
        <ListGroup>
          <ListRow>
            <div className="ac-profile">
              <span className="ac-avatar" aria-hidden="true">{initials(state.userName)}</span>
              <div className="ac-profile-text">
                <span className="ac-name">{state.userName}</span>
                <span className="ac-org">{state.organizationName ?? "Offline workspace"}</span>
              </div>
              <ConnectionBadge state={state.connectionState} />
            </div>
          </ListRow>
        </ListGroup>

        <ListGroup header="Appearance">
          <ListRow>
            <SegmentedControl label="Appearance" value={appearance} onChange={setAppearance} options={APPEARANCES.map((option) => ({ value: option.value, label: option.title, icon: APPEARANCE_ICONS[option.value] }))} />
          </ListRow>
        </ListGroup>

        <ListGroup header="Sync" footer={syncFooter(state.organizationID)}>
          <ListRow label="Status" value={<span className="ac-status">{syncStatusText(state.isWorking, state.syncMessage)}</span>} />
          <ListRow icon={<Icon.Sync />} label="Sync now" accessory={state.isWorking ? <Spinner size={16} /> : undefined} onClick={() => void state.sync()} disabled={state.isWorking} />
          {state.connectionState === "offline" && (
            <>
              <ListRow icon={<Icon.Network />} label="Test API connection" onClick={() => void state.checkConnection()} />
              {state.connectionIssue && <ListRow><span className="ac-issue">{state.connectionIssue}</span></ListRow>}
            </>
          )}
        </ListGroup>

        <ListGroup header="On this device" footer={STORAGE_FOOTER}>
          <ListRow label="Original videos" value={storage ? byteCount(storage.recordings) : "…"} />
          <ListRow label="Rendered videos" value={storage ? byteCount(storage.exports) : "…"} />
          <ListRow label="Thumbnail cache" value={storage ? byteCount(storage.cache) : "…"} />
        </ListGroup>

        <ListGroup>
          <ListRow label="Sign out" destructive onClick={() => setConfirmingSignOut(true)} />
        </ListGroup>
      </div>

      <ConfirmDialog open={confirmingSignOut} onClose={() => setConfirmingSignOut(false)} title="Sign out of Camelot?" message={SIGN_OUT_MESSAGE} confirmLabel="Sign out" onConfirm={() => state.signOut()} />
    </div>
  );
}
