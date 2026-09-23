/* Pure validation behind OnboardingView.swift. */

export type OnboardingMode = "create" | "signIn";

export const MODE_TITLES: Record<OnboardingMode, string> = { create: "Create account", signIn: "Sign in" };

export interface OnboardingInput { mode: OnboardingMode; name: string; email: string; password: string; organization: string }

export const MIN_PASSWORD_LENGTH = 8;

export function passwordHint({ mode, password }: Pick<OnboardingInput, "mode" | "password">): string | null {
  return mode === "create" && password.length > 0 && password.length < MIN_PASSWORD_LENGTH ? "Use at least 8 characters." : null;
}

export function canSubmit({ mode, name, email, password, organization }: OnboardingInput): boolean {
  if (!email.trim() || password.length < MIN_PASSWORD_LENGTH) return false;
  return mode === "signIn" || (name.trim().length > 0 && organization.trim().length > 0);
}

export const CONNECTION_LABELS = { checking: "Checking server", online: "Connected", offline: "Offline" } as const;
