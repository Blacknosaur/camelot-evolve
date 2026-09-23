/* Small cost-bounded LRU. `Map` preserves insertion order, so deleting and re-inserting a key
   moves it to the most-recent end; eviction pops from the front. */

export interface LRUOptions<V> {
  maxCount: number;
  maxCost: number;
  cost?: (value: V) => number;
  onEvict?: (key: string, value: V) => void;
}

export class LRUCache<V> {
  private entries = new Map<string, V>();
  private costs = new Map<string, number>();
  totalCost = 0;

  constructor(private readonly options: LRUOptions<V>) {}

  get size() { return this.entries.size; }

  /** Returns the value and marks it most recently used. */
  get(key: string): V | undefined {
    const value = this.entries.get(key);
    if (value === undefined) return undefined;
    this.entries.delete(key);
    this.entries.set(key, value);
    return value;
  }

  /** Returns the value without touching recency. */
  peek(key: string): V | undefined { return this.entries.get(key); }
  has(key: string) { return this.entries.has(key); }
  keys(): IterableIterator<string> { return this.entries.keys(); }

  set(key: string, value: V) {
    if (this.entries.has(key)) this.delete(key);
    const cost = this.options.cost?.(value) ?? 1;
    this.entries.set(key, value);
    this.costs.set(key, cost);
    this.totalCost += cost;
    this.evict();
  }

  delete(key: string): boolean {
    const value = this.entries.get(key);
    if (value === undefined) return false;
    this.entries.delete(key);
    this.totalCost -= this.costs.get(key) ?? 0;
    this.costs.delete(key);
    this.options.onEvict?.(key, value);
    return true;
  }

  clear() { for (const key of Array.from(this.entries.keys())) this.delete(key); }

  private evict() {
    while (this.entries.size > 1 && (this.entries.size > this.options.maxCount || this.totalCost > this.options.maxCost)) {
      const oldest = this.entries.keys().next().value as string;
      this.delete(oldest);
    }
  }
}
