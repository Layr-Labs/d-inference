/**
 * Pure, DOM-free world-geometry helpers for the dot-matrix map.
 *
 * The source landmass outline ({@link WORLD_LAND_PATH}) is composed entirely of
 * straight `M`/`L` segments across many closed (`Z`) subpaths. We parse those
 * into polygon rings and use ray-casting point-in-polygon tests — no canvas, no
 * `window`, no DOM — so the dot field can be generated identically on the server
 * (static prerender) and the client (hydration). Everything here is deterministic
 * and unit-testable.
 */

import { WORLD_LAND_PATH } from "./worldLandPath";

export interface Point {
  x: number;
  y: number;
}

interface Ring {
  points: Point[];
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

/** Default viewBox the map is authored in. */
export const MAP_WIDTH = 1000;
export const MAP_HEIGHT = 500;
/** Default land-dot grid spacing (viewBox units). */
export const DEFAULT_DOT_SPACING = 11;

/**
 * Rings thinner than this in either bbox dimension are dropped before dot
 * sampling. The source path contains a couple of full-width ~2px "seam" slivers
 * (around y≈52 and y≈295) that are rendering artifacts, not land; filtering by a
 * minimum extent removes them without touching real islands (smallest of which
 * spans ~3px+).
 */
const MIN_RING_EXTENT = 2.5;

// Matches a single numeric token. Coordinates arrive in x,y order and are paired
// by a running toggle below, so no dynamic-index array access is needed. The
// pattern is a single linear char class (no backtracking risk).
const NUMBER_TOKEN = /-?[0-9.]+/g;

/**
 * Parse an all-straight-segment SVG path into polygon rings. Each `Z`-terminated
 * subpath becomes one ring; numeric tokens stream out in `x, y` order and are
 * paired into vertices.
 */
export function parsePolygons(pathData: string): Point[][] {
  const rings: Point[][] = [];
  for (const chunk of pathData.split(/[zZ]/)) {
    const points: Point[] = [];
    let pendingX: number | null = null;
    for (const match of chunk.matchAll(NUMBER_TOKEN)) {
      const value = Number.parseFloat(match[0]);
      if (Number.isNaN(value)) continue;
      if (pendingX === null) {
        pendingX = value;
      } else {
        points.push({ x: pendingX, y: value });
        pendingX = null;
      }
    }
    if (points.length >= 3) rings.push(points);
  }
  return rings;
}

/**
 * Even-odd ray-casting point-in-polygon test for a single ring. Casts a ray to
 * +x and counts edge crossings (each edge is the segment from the previous vertex
 * to the current one); an odd count means the point is inside.
 */
export function pointInPolygon(point: Point, ring: Point[]): boolean {
  let prev = ring.at(-1);
  if (!prev) return false;
  let inside = false;
  for (const curr of ring) {
    const straddles = curr.y > point.y !== prev.y > point.y;
    if (straddles && point.x < ((prev.x - curr.x) * (point.y - curr.y)) / (prev.y - curr.y) + curr.x) {
      inside = !inside;
    }
    prev = curr;
  }
  return inside;
}

/**
 * Land test across many rings using the even-odd fill rule (inside an odd number
 * of rings → land). This naturally carves out any nested holes.
 */
export function isPointOnLand(point: Point, rings: Point[][]): boolean {
  let crossings = 0;
  for (const ring of rings) {
    if (pointInPolygon(point, ring)) crossings += 1;
  }
  return crossings % 2 === 1;
}

function withBoundingBox(points: Point[]): Ring {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const p of points) {
    if (p.x < minX) minX = p.x;
    if (p.x > maxX) maxX = p.x;
    if (p.y < minY) minY = p.y;
    if (p.y > maxY) maxY = p.y;
  }
  return { points, minX, minY, maxX, maxY };
}

export interface LandDotOptions {
  pathData?: string;
  width?: number;
  height?: number;
  spacing?: number;
}

/** Even-odd land test against pre-bbox'd rings, skipping rings whose box excludes the point. */
function isOnPreparedLand(x: number, y: number, rings: Ring[]): boolean {
  let crossings = 0;
  for (const ring of rings) {
    if (x < ring.minX || x > ring.maxX || y < ring.minY || y > ring.maxY) continue;
    if (pointInPolygon({ x, y }, ring.points)) crossings += 1;
  }
  return crossings % 2 === 1;
}

/**
 * Build an evenly-spaced grid over the viewBox and keep the cell centers that
 * fall on land. Each ring carries a bounding box so most ocean samples skip the
 * full ray cast. Output order is deterministic (row-major), so server and client
 * render byte-identical dot fields.
 */
export function generateLandDots({
  pathData = WORLD_LAND_PATH,
  width = MAP_WIDTH,
  height = MAP_HEIGHT,
  spacing = DEFAULT_DOT_SPACING,
}: LandDotOptions = {}): Point[] {
  const step = spacing > 0 ? spacing : DEFAULT_DOT_SPACING;
  const rings = parsePolygons(pathData)
    .map(withBoundingBox)
    .filter((ring) => ring.maxX - ring.minX >= MIN_RING_EXTENT && ring.maxY - ring.minY >= MIN_RING_EXTENT);

  const dots: Point[] = [];
  for (let y = step / 2; y <= height; y += step) {
    for (let x = step / 2; x <= width; x += step) {
      if (isOnPreparedLand(x, y, rings)) dots.push({ x, y });
    }
  }
  return dots;
}

/**
 * Encode a set of dots as a single SVG path (each dot is two semicircular arcs).
 * One `<path>` paints far faster than thousands of `<circle>` nodes.
 */
export function dotsToPathData(dots: Point[], radius: number): string {
  const r = Number(radius.toFixed(2));
  const d = (radius * 2).toFixed(2);
  const nd = (-radius * 2).toFixed(2);
  const arc = `a${r} ${r} 0 1 0`;
  let path = "";
  for (const dot of dots) {
    const x = (dot.x - radius).toFixed(2);
    const y = dot.y.toFixed(2);
    path += `M${x} ${y}${arc} ${d} 0${arc} ${nd} 0z`;
  }
  return path;
}

const dotCache = new Map<number, Point[]>();

/** Memoized land-dot generation keyed by spacing (shared across map instances). */
export function getLandDots(spacing = DEFAULT_DOT_SPACING): Point[] {
  const cached = dotCache.get(spacing);
  if (cached) return cached;
  const dots = generateLandDots({ spacing });
  dotCache.set(spacing, dots);
  return dots;
}
