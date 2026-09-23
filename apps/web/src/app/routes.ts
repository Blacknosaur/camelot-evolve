/* Route table paths. Kept separate from router.tsx so screens and tests can link to routes
   without instantiating the browser router. Feature agents: keep these paths stable. */
export const routes = {
  welcome: "/welcome",
  projects: "/",
  project: (id: string) => `/projects/${id}`,
  camera: (id: string) => `/projects/${id}/camera`,
  recording: (projectID: string, recordingID: string) => `/projects/${projectID}/recordings/${recordingID}`,
  edit: (projectID: string, compositionID: string) => `/projects/${projectID}/edit/${compositionID}`,
  analyze: (projectID: string, compositionID: string, clipID: string) => `/projects/${projectID}/edit/${compositionID}/analyze/${clipID}`,
  watch: (projectID: string, compositionID: string) => `/projects/${projectID}/watch/${compositionID}`,
  account: "/account",
} as const;
