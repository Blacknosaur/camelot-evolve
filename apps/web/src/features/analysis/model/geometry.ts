import type { Point } from "@/domain/geometry";

/** Andrew's monotone chain (port of `GameAnnotationEffects.convexHull`). Player areas stay a valid
 *  envelope when two players exchange order; hand-drawn areas keep their authored concave shape. */
export function convexHull(points: readonly Point[]): Point[] {
  const sorted = [...points].sort((a, b) => (a.x === b.x ? a.y - b.y : a.x - b.x));
  if (sorted.length <= 2) return sorted;
  const half = (input: Point[]) => {
    const result: Point[] = [];
    for (const point of input) {
      while (result.length >= 2) {
        const a = result[result.length - 2]!, b = result[result.length - 1]!;
        if ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) > 0) break;
        result.pop();
      }
      result.push(point);
    }
    return result;
  };
  const lower = half(sorted), upper = half([...sorted].reverse());
  return [...lower.slice(0, -1), ...upper.slice(0, -1)];
}
