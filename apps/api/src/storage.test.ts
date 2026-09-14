import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { LocalObjectStore } from "./storage.js";

describe("LocalObjectStore", () => {
  let directory: string | undefined;
  afterEach(async () => { if (directory) await rm(directory, { recursive: true, force: true }); });

  it("assembles multipart data and serves ranges", async () => {
    directory = await mkdtemp(path.join(tmpdir(), "camelot-storage-"));
    const store = new LocalObjectStore(directory);
    const uploadId = await store.createMultipart("assets/video", "video/quicktime");
    await store.putPart("assets/video", uploadId, 1, new TextEncoder().encode("first"));
    await store.putPart("assets/video", uploadId, 2, new TextEncoder().encode("second"));
    await store.completeMultipart("assets/video", uploadId, [{ partNumber: 1 }, { partNumber: 2 }]);
    const result = await store.read("assets/video", "bytes=3-7");
    expect(result.range).toBe("bytes 3-7/11");
    expect(await new Response(result.body).text()).toBe("stsec");
  });
});
