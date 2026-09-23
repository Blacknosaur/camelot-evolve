import { describe, expect, it } from "vitest";
import { initials, syncFooter, syncStatusText } from "./account-logic";

describe("initials", () => {
  it("takes the first letter of up to two words", () => {
    expect(initials("Miguel Costa")).toBe("MC");
    expect(initials("miguel")).toBe("M");
    expect(initials("Ana Maria Silva")).toBe("AM");
    expect(initials("   ")).toBe("C");
    expect(initials("coach@example.com")).toBe("C");
  });
});

describe("syncStatusText", () => {
  it("prefers the working state, then the message, then Idle", () => {
    expect(syncStatusText(true, "Synced successfully.")).toBe("Syncing…");
    expect(syncStatusText(false, "Synced successfully.")).toBe("Synced successfully.");
    expect(syncStatusText(false, null)).toBe("Idle");
  });
});

describe("syncFooter", () => {
  it("explains the organization requirement", () => {
    expect(syncFooter(null)).toMatch(/Create or join an organization/);
    expect(syncFooter("org")).toMatch(/every 15 seconds/);
  });
});
