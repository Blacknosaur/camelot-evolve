import { useEffect } from "react";
import { NavLink, Outlet } from "react-router";
import { Icon } from "@/design/icons";
import { routes } from "./routes";
import { useAppState } from "./app-state";
import "./AppShell.css";

const SYNC_INTERVAL_MS = 15_000;

/** Library surfaces: Projects and Account tabs (bottom bar on phones, side rail on wide windows).
 *  Port of MainTabView: checks the server once and syncs every 15 seconds while mounted. */
export function AppShell() {
  const checkConnection = useAppState((s) => s.checkConnection);
  const sync = useAppState((s) => s.sync);
  const organizationID = useAppState((s) => s.organizationID);

  useEffect(() => {
    let cancelled = false;
    void checkConnection();
    const tick = () => { if (!cancelled) void sync(); };
    tick();
    const timer = setInterval(tick, SYNC_INTERVAL_MS);
    return () => { cancelled = true; clearInterval(timer); };
  }, [checkConnection, sync, organizationID]);

  return (
    <div className="shell">
      <nav className="shell-tabs" aria-label="Main">
        <div className="shell-brand" aria-hidden="true"><Icon.Logo /></div>
        <NavLink to={routes.projects} end className={({ isActive }) => `shell-tab ${isActive ? "active" : ""}`}><Icon.Stack /><span>Projects</span></NavLink>
        <NavLink to={routes.account} className={({ isActive }) => `shell-tab ${isActive ? "active" : ""}`}><Icon.Person /><span>Account</span></NavLink>
      </nav>
      <main className="shell-content"><Outlet /></main>
    </div>
  );
}
