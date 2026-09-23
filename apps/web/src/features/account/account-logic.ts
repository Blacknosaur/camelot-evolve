/* Pure helpers behind SettingsView (MainTabView.swift). */

/** Up to two initials from the display name; "C" when the name is blank. */
export function initials(userName: string): string {
  const letters = userName.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]!).join("");
  return letters ? letters.toUpperCase() : "C";
}

export function syncStatusText(isWorking: boolean, syncMessage: string | null): string {
  if (isWorking) return "Syncing…";
  return syncMessage ?? "Idle";
}

export function syncFooter(organizationID: string | null): string {
  return organizationID == null
    ? "Create or join an organization to sync. Everything stays saved on this device."
    : "Camelot syncs metadata every 15 seconds and uploads videos in the background.";
}

export const STORAGE_FOOTER = "Videos are stored in this browser's private storage and are never uploaded without sync. Delete a video from its project to free space.";
export const SIGN_OUT_MESSAGE = "Projects and videos stay on this device. Sign in again to keep syncing.";
