import { describe, expect, it } from "vitest";
import {
  MAP_HEIGHT,
  MAP_WIDTH,
  dotsToPathData,
  generateLandDots,
  getLandDots,
  isPointOnLand,
  parsePolygons,
  pointInPolygon,
  type Point,
} from "./worldGeometry";
import { WORLD_LAND_PATH } from "./worldLandPath";

const SQUARE = "M 100 100 L 300 100 L 300 300 L 100 300 Z";

describe("parsePolygons", () => {
  it("parses each Z-terminated subpath into a ring of vertices", () => {
    const rings = parsePolygons("M0 0 L10 0 L10 10 L0 10 Z M20 20 L30 20 L25 30 Z");
    expect(rings).toHaveLength(2);
    expect(rings[0]).toEqual([
      { x: 0, y: 0 },
      { x: 10, y: 0 },
      { x: 10, y: 10 },
      { x: 0, y: 10 },
    ]);
    expect(rings[1]).toHaveLength(3);
  });

  it("handles missing spaces after commands and drops degenerate subpaths", () => {
    const rings = parsePolygons("M0.0 1.0L2.5 3.5L4.0 0.0Z M9 9 L9 9 Z");
    expect(rings).toHaveLength(1);
    expect(rings[0]).toEqual([
      { x: 0, y: 1 },
      { x: 2.5, y: 3.5 },
      { x: 4, y: 0 },
    ]);
  });
});

describe("pointInPolygon", () => {
  const square: Point[] = [
    { x: 100, y: 100 },
    { x: 300, y: 100 },
    { x: 300, y: 300 },
    { x: 100, y: 300 },
  ];

  it("returns true for interior points", () => {
    expect(pointInPolygon({ x: 200, y: 200 }, square)).toBe(true);
    expect(pointInPolygon({ x: 110, y: 290 }, square)).toBe(true);
  });

  it("returns false for exterior points on every side", () => {
    expect(pointInPolygon({ x: 50, y: 200 }, square)).toBe(false);
    expect(pointInPolygon({ x: 350, y: 200 }, square)).toBe(false);
    expect(pointInPolygon({ x: 200, y: 50 }, square)).toBe(false);
    expect(pointInPolygon({ x: 200, y: 350 }, square)).toBe(false);
  });

  it("classifies points against a non-convex (L-shaped) polygon", () => {
    const lShape: Point[] = [
      { x: 0, y: 0 },
      { x: 40, y: 0 },
      { x: 40, y: 20 },
      { x: 20, y: 20 },
      { x: 20, y: 40 },
      { x: 0, y: 40 },
    ];
    expect(pointInPolygon({ x: 10, y: 10 }, lShape)).toBe(true);
    expect(pointInPolygon({ x: 30, y: 30 }, lShape)).toBe(false); // in the notch
  });
});

describe("isPointOnLand (even-odd across rings)", () => {
  const outer: Point[] = [
    { x: 0, y: 0 },
    { x: 100, y: 0 },
    { x: 100, y: 100 },
    { x: 0, y: 100 },
  ];
  const hole: Point[] = [
    { x: 25, y: 25 },
    { x: 75, y: 25 },
    { x: 75, y: 75 },
    { x: 25, y: 75 },
  ];

  it("treats a nested ring as a carved-out hole", () => {
    expect(isPointOnLand({ x: 10, y: 10 }, [outer, hole])).toBe(true); // ring only
    expect(isPointOnLand({ x: 50, y: 50 }, [outer, hole])).toBe(false); // in hole
    expect(isPointOnLand({ x: 200, y: 200 }, [outer, hole])).toBe(false); // outside
  });
});

describe("generateLandDots", () => {
  it("only returns points strictly inside the land shape", () => {
    const dots = generateLandDots({ pathData: SQUARE, spacing: 20, width: 400, height: 400 });
    expect(dots.length).toBeGreaterThan(0);
    for (const dot of dots) {
      expect(dot.x).toBeGreaterThan(100);
      expect(dot.x).toBeLessThan(300);
      expect(dot.y).toBeGreaterThan(100);
      expect(dot.y).toBeLessThan(300);
    }
  });

  it("produces a full interior grid for a simple square", () => {
    const dots = generateLandDots({ pathData: SQUARE, spacing: 20, width: 400, height: 400 });
    // Grid centers at 10,30,...,390; those inside (100,300) are 110..290 → 10 per axis.
    expect(dots).toHaveLength(100);
  });

  it("is deterministic across calls", () => {
    const a = generateLandDots({ pathData: SQUARE, spacing: 25, width: 400, height: 400 });
    const b = generateLandDots({ pathData: SQUARE, spacing: 25, width: 400, height: 400 });
    expect(a).toEqual(b);
  });

  it("derives a sane, in-bounds dot field from the real world path", () => {
    const dots = getLandDots();
    expect(dots.length).toBeGreaterThan(400);
    expect(dots.length).toBeLessThan(6000);
    for (const dot of dots) {
      expect(dot.x).toBeGreaterThanOrEqual(0);
      expect(dot.x).toBeLessThanOrEqual(MAP_WIDTH);
      expect(dot.y).toBeGreaterThanOrEqual(0);
      expect(dot.y).toBeLessThanOrEqual(MAP_HEIGHT);
    }
    // Cached call returns the identical reference.
    expect(getLandDots()).toBe(dots);
  });

  it("keeps real-world generation deterministic", () => {
    expect(generateLandDots()).toEqual(generateLandDots());
    expect(parsePolygons(WORLD_LAND_PATH).length).toBeGreaterThan(20);
  });
});

describe("dotsToPathData", () => {
  it("emits one move-and-two-arcs subpath per dot", () => {
    const path = dotsToPathData(
      [
        { x: 10, y: 20 },
        { x: 30, y: 40 },
      ],
      1.5,
    );
    expect(path.match(/M/g)).toHaveLength(2);
    expect(path.match(/a/g)).toHaveLength(4);
    expect(path).toContain("z");
  });

  it("is deterministic", () => {
    const dots = [{ x: 1, y: 2 }];
    expect(dotsToPathData(dots, 2)).toBe(dotsToPathData(dots, 2));
  });
});
