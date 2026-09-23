import { serveJobs } from "./host";
import { renderComposition } from "@/features/export/render";

/* OWNER: export agent. Renders a VideoComposition to MP4/WebM off the main thread. The heavy lifting
   (decode → retime → crop → annotate → encode → mux into the media store) lives in features/export/render.ts
   so tests and a future service worker can reuse it. */

serveJobs({
  "export.render": (input, context) => renderComposition(input, context),
});
