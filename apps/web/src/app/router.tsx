import { createBrowserRouter, Navigate, Outlet } from "react-router";
import { AppShell } from "./AppShell";
import { RequireAuth } from "./RequireAuth";
import { routes } from "./routes";

/* Route table. Feature agents replace the lazy placeholders below with their screens;
   keep the paths stable — other features link to them. */
const lazy = (loader: () => Promise<{ default: React.ComponentType }>) => async () => ({ Component: (await loader()).default });

export { routes };

export const router = createBrowserRouter([{
  /* Lazy routes need a hydrate fallback; a blank frame avoids a flash of placeholder text. */
  hydrateFallbackElement: <div style={{ height: "100%", background: "var(--bg)" }} />,
  children: [
  { path: routes.welcome, lazy: lazy(() => import("@/features/onboarding/OnboardingScreen")) },
  {
    element: <RequireAuth><Outlet /></RequireAuth>,
    children: [
      {
        element: <AppShell />,
        children: [
          { path: routes.projects, lazy: lazy(() => import("@/features/projects/ProjectsScreen")) },
          { path: "/projects/:projectID", lazy: lazy(() => import("@/features/project-detail/ProjectDetailScreen")) },
          { path: routes.account, lazy: lazy(() => import("@/features/account/AccountScreen")) },
        ],
      },
      /* Full-bleed dark surfaces without the tab bar. */
      { path: "/projects/:projectID/camera", lazy: lazy(() => import("@/features/camera/CameraScreen")) },
      { path: "/projects/:projectID/recordings/:recordingID", lazy: lazy(() => import("@/features/player/RecordingPlayerScreen")) },
      { path: "/projects/:projectID/edit/:compositionID", lazy: lazy(() => import("@/features/editor/EditorScreen")) },
      { path: "/projects/:projectID/edit/:compositionID/analyze/:clipID", lazy: lazy(() => import("@/features/analysis/AnalysisScreen")) },
      { path: "/projects/:projectID/watch/:compositionID", lazy: lazy(() => import("@/features/player/CompositionPlayerScreen")) },
    ],
  },
  { path: "*", element: <Navigate to={routes.projects} replace /> },
]}]);
