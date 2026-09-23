import { useEffect, useState } from "react";
import { useNavigate } from "react-router";
import { useAppState } from "@/app/app-state";
import { routes } from "@/app/routes";
import { Banner, Button, Card, Field, SegmentedControl, Spinner, StatusPill } from "@/design/components";
import { Icon } from "@/design/icons";
import { useLayoutMetrics } from "@/design/layout";
import { CONNECTION_LABELS, MODE_TITLES, canSubmit, passwordHint, type OnboardingMode } from "./onboarding-logic";
import "./OnboardingScreen.css";

/** Port of OnboardingView: create account / sign in, or continue offline. */
export default function OnboardingScreen() {
  const navigate = useNavigate();
  const [ref, layout] = useLayoutMetrics<HTMLDivElement>();
  const state = useAppState();
  const [mode, setMode] = useState<OnboardingMode>("create");
  const [name, setName] = useState("");
  const [organization, setOrganization] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showsPassword, setShowsPassword] = useState(false);
  const checkConnection = state.checkConnection;

  useEffect(() => { void checkConnection(); }, [checkConnection]);
  useEffect(() => { if (state.isAuthenticated) navigate(routes.projects, { replace: true }); }, [state.isAuthenticated, navigate]);

  const input = { mode, name, email, password, organization };
  const submittable = canSubmit(input) && !state.isWorking;
  const hint = passwordHint(input);
  const twoColumn = layout.isLandscape && layout.width >= 640;

  const submit = () => {
    if (!submittable) return;
    (document.activeElement as HTMLElement | null)?.blur();
    if (mode === "create") void state.createAccount({ name: name.trim(), email: email.trim(), password, organization: organization.trim() });
    else void state.signInWithPassword({ email: email.trim(), password });
  };

  const hero = (compact: boolean) => (
    <div className="ob-hero">
      <div className="ob-brand">
        <span className={`ob-logo ${compact ? "ob-logo-compact" : ""}`}><Icon.Logo /></span>
        <span className="ob-brand-name">Camelot</span>
      </div>
      {!compact && (
        <>
          <h1 className="ob-headline">Record the match.<br />Capture what matters.</h1>
          <p className="ob-lede">Projects, videos and tagged events stay on this device and sync when you are back online.</p>
        </>
      )}
    </div>
  );

  return (
    <div ref={ref} className="ob">
      <div className={`ob-layout ${twoColumn ? "ob-layout-wide" : ""}`}>
        {hero(!twoColumn && layout.isShort)}
        <Card className="ob-card">
          <form className="ob-form" onSubmit={(event) => { event.preventDefault(); submit(); }}>
            <SegmentedControl label="Account action" value={mode} onChange={setMode} options={[{ value: "create", label: MODE_TITLES.create }, { value: "signIn", label: MODE_TITLES.signIn }]} />
            <div className="ob-fields">
              {mode === "create" && (
                <>
                  <Field icon={<Icon.Person />}><input className="ds-input" placeholder="Your name" value={name} onChange={(e) => setName(e.target.value)} autoComplete="name" enterKeyHint="next" aria-label="Your name" /></Field>
                  <Field icon={<Icon.Shield />}><input className="ds-input" placeholder="Club or organization" value={organization} onChange={(e) => setOrganization(e.target.value)} autoComplete="organization" enterKeyHint="next" aria-label="Club or organization" /></Field>
                </>
              )}
              <Field icon={<Icon.Envelope />}><input className="ds-input" type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} autoComplete="email" autoCapitalize="none" spellCheck={false} enterKeyHint="next" aria-label="Email" /></Field>
              <Field icon={<Icon.Lock />} hint={hint ?? undefined} trailing={<PasswordToggle shown={showsPassword} onToggle={() => setShowsPassword((v) => !v)} />}>
                <input className="ds-input" type={showsPassword ? "text" : "password"} placeholder="Password" value={password} onChange={(e) => setPassword(e.target.value)} autoComplete={mode === "create" ? "new-password" : "current-password"} enterKeyHint="go" aria-label="Password" />
              </Field>
            </div>

            {state.errorMessage && <Banner icon={<Icon.Warning />}>{state.errorMessage}</Banner>}

            <Button type="submit" variant="primary" disabled={!submittable} data-testid="onboarding-submit">
              {state.isWorking && <Spinner size={16} />}
              {MODE_TITLES[mode]}
            </Button>
            <Button variant="secondary" disabled={state.isWorking} onClick={() => state.continueOffline(name)}>Continue offline</Button>

            <div className="ob-connection">
              <ConnectionBadge state={state.connectionState} />
              {state.connectionState === "offline" && (
                <>
                  {state.connectionIssue && <p className="ob-issue">{state.connectionIssue}</p>}
                  <Button variant="plain" className="ob-retry" onClick={() => void checkConnection()}><Icon.Refresh />Retry connection</Button>
                </>
              )}
            </div>
          </form>
        </Card>
      </div>
    </div>
  );
}

function PasswordToggle({ shown, onToggle }: { shown: boolean; onToggle: () => void }) {
  return (
    <button type="button" className="ob-eye" aria-label={shown ? "Hide password" : "Show password"} onClick={onToggle}>
      {shown ? <Icon.EyeOff /> : <Icon.Eye />}
    </button>
  );
}

/** Connection status chip shared between onboarding and account (port of ConnectionBadge). */
export function ConnectionBadge({ state }: { state: "checking" | "online" | "offline" }) {
  const icon = state === "checking" ? <Icon.Sync /> : state === "online" ? <Icon.CheckCircle /> : <Icon.WifiOff />;
  const tint = state === "checking" ? "var(--fg-secondary)" : state === "online" ? "var(--success)" : "var(--warning)";
  return <StatusPill text={CONNECTION_LABELS[state]} tint={tint} icon={icon} />;
}
