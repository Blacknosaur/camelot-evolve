import { describe, expect, it } from "vitest";
import { fileExtension, mimeTypeForKey, progressStream } from "./import";
import { thumbnailBucketMs, thumbnailKey } from "./thumbnail-keys";

describe("import helpers", () => {
  it("derives the extension from the name, then the MIME type, then mp4", () => {
    expect(fileExtension({ name: "Match.MOV", type: "video/quicktime" })).toBe("mov");
    expect(fileExtension({ name: "clip", type: "video/webm" })).toBe("webm");
    expect(fileExtension({ name: "clip", type: "" })).toBe("mp4");
    expect(mimeTypeForKey("A.mov")).toBe("video/quicktime");
  });

  it("reports write progress as a fraction of the total size", async () => {
    const fractions: number[] = [];
    const bytes = new Uint8Array(10);
    const source = new ReadableStream<Uint8Array>({ start(c) { c.enqueue(bytes.slice(0, 4)); c.enqueue(bytes.slice(4)); c.close(); } });
    const out = await new Response(progressStream(source, 10, (f) => fractions.push(f))).arrayBuffer();
    expect(out.byteLength).toBe(10);
    expect(fractions).toEqual([0.4, 1]);
  });

  it("buckets thumbnail times to quarter seconds", () => {
    expect(thumbnailBucketMs(0)).toBe(0);
    expect(thumbnailBucketMs(1.1)).toBe(1000);
    expect(thumbnailBucketMs(1.13)).toBe(1250);
    expect(thumbnailBucketMs(-2)).toBe(0);
    expect(thumbnailKey("R", 3.9, 120.4)).toBe("R-4000-120.jpg");
  });
});
