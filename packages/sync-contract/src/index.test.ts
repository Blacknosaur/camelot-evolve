import { describe, expect, it } from "vitest";
import { pushRequestSchema } from "./index.js";

describe("sync contract", () => {
  it("rejects an empty mutation batch", () => {
    expect(() => pushRequestSchema.parse({ organizationId: "org", deviceId: crypto.randomUUID(), mutations: [] })).toThrow();
  });
});

