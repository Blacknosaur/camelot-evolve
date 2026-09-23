import type { ReactNode } from "react";
import { Navigate } from "react-router";
import { useAppState } from "./app-state";
import { routes } from "./routes";

/** Mirrors RootView: authenticated (or offline workspace) → main tabs, otherwise onboarding. */
export function RequireAuth({ children }: { children: ReactNode }) {
  const isAuthenticated = useAppState((s) => s.isAuthenticated);
  return isAuthenticated ? <>{children}</> : <Navigate to={routes.welcome} replace />;
}
