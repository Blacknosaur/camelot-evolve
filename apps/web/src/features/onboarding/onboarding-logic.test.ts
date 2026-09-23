import { describe, expect, it } from "vitest";
import { canSubmit, passwordHint } from "./onboarding-logic";
import { organizationSlug } from "@/app/api-client";

describe("canSubmit", () => {
  it("requires name and organization only when creating an account", () => {
    expect(canSubmit({ mode: "signIn", name: "", organization: "", email: "a@b.c", password: "12345678" })).toBe(true);
    expect(canSubmit({ mode: "create", name: "", organization: "", email: "a@b.c", password: "12345678" })).toBe(false);
    expect(canSubmit({ mode: "create", name: "Ana", organization: "FC", email: "a@b.c", password: "12345678" })).toBe(true);
  });
  it("rejects short passwords and blank emails", () => {
    expect(canSubmit({ mode: "signIn", name: "", organization: "", email: "a@b.c", password: "1234567" })).toBe(false);
    expect(canSubmit({ mode: "signIn", name: "", organization: "", email: "  ", password: "12345678" })).toBe(false);
  });
});

describe("passwordHint", () => {
  it("only hints while creating with a short non-empty password", () => {
    expect(passwordHint({ mode: "create", password: "abc" })).toBe("Use at least 8 characters.");
    expect(passwordHint({ mode: "create", password: "" })).toBeNull();
    expect(passwordHint({ mode: "create", password: "abcdefgh" })).toBeNull();
    expect(passwordHint({ mode: "signIn", password: "abc" })).toBeNull();
  });
});

describe("organizationSlug", () => {
  it("lowercases, dashes non-alphanumerics and appends the suffix", () => {
    expect(organizationSlug("FC Rovers!! United", "abc123")).toBe("fc-rovers-united-abc123");
    expect(organizationSlug("--Edge--", "x")).toBe("edge-x");
  });
});
