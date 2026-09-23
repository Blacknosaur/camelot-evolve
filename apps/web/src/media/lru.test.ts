import { describe, expect, it } from "vitest";
import { LRUCache } from "./lru";

describe("LRUCache", () => {
  it("evicts the least recently used entry past maxCount", () => {
    const evicted: string[] = [];
    const cache = new LRUCache<number>({ maxCount: 2, maxCost: Infinity, onEvict: (k) => evicted.push(k) });
    cache.set("a", 1); cache.set("b", 2);
    expect(cache.get("a")).toBe(1); // touch a → b is now oldest
    cache.set("c", 3);
    expect(evicted).toEqual(["b"]);
    expect(cache.has("a")).toBe(true);
    expect(cache.has("c")).toBe(true);
  });

  it("evicts by cost and tracks totalCost", () => {
    const cache = new LRUCache<number>({ maxCount: 100, maxCost: 10, cost: (v) => v });
    cache.set("a", 4); cache.set("b", 4); cache.set("c", 4);
    expect(cache.has("a")).toBe(false);
    expect(cache.totalCost).toBe(8);
    cache.set("big", 50); // one oversized entry is still kept
    expect(cache.size).toBe(1);
    expect(cache.peek("big")).toBe(50);
  });

  it("peek does not change recency and re-set replaces cost", () => {
    const cache = new LRUCache<number>({ maxCount: 2, maxCost: Infinity, cost: (v) => v });
    cache.set("a", 1); cache.set("b", 1);
    cache.peek("a");
    cache.set("c", 1);
    expect(cache.has("a")).toBe(false);
    cache.set("b", 7);
    expect(cache.totalCost).toBe(8);
    cache.clear();
    expect(cache.size).toBe(0);
    expect(cache.totalCost).toBe(0);
  });
});
