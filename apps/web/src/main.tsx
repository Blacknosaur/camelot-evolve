import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { RouterProvider } from "react-router";
import "./design/tokens.css";
import { router } from "./app/router";
import { applyStoredAppearance } from "./app/appearance";

applyStoredAppearance();
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);
