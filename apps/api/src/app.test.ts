import { describe, expect, it, vi } from "vitest";
import { createApp } from "./app.js";

describe("api", () => {
  it("reports health without a database connection", async () => {
    const app = createApp({} as never, { handler: vi.fn(), api: {} } as never);
    const response = await app.request("/api/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });
});

