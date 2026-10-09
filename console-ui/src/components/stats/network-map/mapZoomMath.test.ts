import { describe, expect, it } from "vitest";
import {
  IDENTITY_TRANSFORM,
  MAX_SCALE,
  MIN_SCALE,
  canZoomIn,
  canZoomOut,
  clampScale,
  clampTranslation,
  mapTransformToCss,
  zoomAtPoint,
  type ViewportSize,
} from "./mapZoomMath";

const SIZE: ViewportSize = { width: 1000, height: 500 };

describe("clampScale", () => {
  it("clamps below the minimum up to MIN_SCALE", () => {
    expect(clampScale(0)).toBe(MIN_SCALE);
    expect(clampScale(0.25)).toBe(MIN_SCALE);
    expect(clampScale(-3)).toBe(MIN_SCALE);
  });

  it("clamps above the maximum down to MAX_SCALE", () => {
    expect(clampScale(20)).toBe(MAX_SCALE);
    expect(clampScale(Number.POSITIVE_INFINITY)).toBe(MAX_SCALE);
  });

  it("passes through in-range values and defaults NaN to the minimum", () => {
    expect(clampScale(3.5)).toBe(3.5);
    expect(clampScale(Number.NaN)).toBe(MIN_SCALE);
  });
});

describe("zoomAtPoint", () => {
  it("keeps the point under the cursor stationary", () => {
    const pointerX = 720;
    const pointerY = 180;
    const next = zoomAtPoint(IDENTITY_TRANSFORM, pointerX, pointerY, 2, SIZE);

    // Screen position of the local point that was under the cursor must not move.
    const localX = (pointerX - IDENTITY_TRANSFORM.tx) / IDENTITY_TRANSFORM.scale;
    const localY = (pointerY - IDENTITY_TRANSFORM.ty) / IDENTITY_TRANSFORM.scale;
    expect(localX * next.scale + next.tx).toBeCloseTo(pointerX, 6);
    expect(localY * next.scale + next.ty).toBeCloseTo(pointerY, 6);
  });

  it("keeps the anchor stationary across a second, off-center zoom step", () => {
    const start = zoomAtPoint(IDENTITY_TRANSFORM, 500, 250, 3, SIZE);
    const pointerX = 300;
    const pointerY = 360;
    const next = zoomAtPoint(start, pointerX, pointerY, 1.5, SIZE);

    const localX = (pointerX - start.tx) / start.scale;
    const localY = (pointerY - start.ty) / start.scale;
    expect(localX * next.scale + next.tx).toBeCloseTo(pointerX, 6);
    expect(localY * next.scale + next.ty).toBeCloseTo(pointerY, 6);
  });

  it("respects the scale clamp when zooming far in", () => {
    const next = zoomAtPoint(IDENTITY_TRANSFORM, 500, 250, 1000, SIZE);
    expect(next.scale).toBe(MAX_SCALE);
  });

  it("respects the scale clamp when zooming far out", () => {
    const zoomed = zoomAtPoint(IDENTITY_TRANSFORM, 500, 250, 4, SIZE);
    const next = zoomAtPoint(zoomed, 500, 250, 0.001, SIZE);
    expect(next.scale).toBe(MIN_SCALE);
    // Back at scale 1 the framing is reset to the origin.
    expect(next.tx).toBe(0);
    expect(next.ty).toBe(0);
  });

  it("never produces a translation that exposes a gap", () => {
    // Zoom hard toward a corner; the result must still cover the container.
    const next = zoomAtPoint(IDENTITY_TRANSFORM, 0, 0, 6, SIZE);
    expect(next.tx).toBeLessThanOrEqual(0);
    expect(next.ty).toBeLessThanOrEqual(0);
    expect(next.tx).toBeGreaterThanOrEqual(SIZE.width * (1 - next.scale) - 1e-9);
    expect(next.ty).toBeGreaterThanOrEqual(SIZE.height * (1 - next.scale) - 1e-9);
  });
});

describe("clampTranslation", () => {
  it("forces zero translation at scale 1", () => {
    expect(clampTranslation({ scale: 1, tx: 250, ty: -120 }, SIZE)).toEqual({
      scale: 1,
      tx: 0,
      ty: 0,
    });
  });

  it("never lets the scaled layer leave the viewport", () => {
    const scale = 4;
    const minTx = SIZE.width * (1 - scale);
    const minTy = SIZE.height * (1 - scale);

    // Over-pan in every direction; result stays within [min, 0] on both axes.
    const pannedRightDown = clampTranslation({ scale, tx: 9999, ty: 9999 }, SIZE);
    expect(pannedRightDown.tx).toBe(0);
    expect(pannedRightDown.ty).toBe(0);

    const pannedLeftUp = clampTranslation({ scale, tx: -9999, ty: -9999 }, SIZE);
    expect(pannedLeftUp.tx).toBe(minTx);
    expect(pannedLeftUp.ty).toBe(minTy);
  });

  it("clamps the scale before bounding the translation", () => {
    const result = clampTranslation({ scale: 99, tx: -100000, ty: -100000 }, SIZE);
    expect(result.scale).toBe(MAX_SCALE);
    expect(result.tx).toBe(SIZE.width * (1 - MAX_SCALE));
    expect(result.ty).toBe(SIZE.height * (1 - MAX_SCALE));
  });

  it("treats a zero/degenerate size as no panning room", () => {
    const result = clampTranslation({ scale: 5, tx: -42, ty: 42 }, { width: 0, height: 0 });
    expect(result).toEqual({ scale: 5, tx: 0, ty: 0 });
  });
});

describe("zoom availability gating", () => {
  it("disables zoom-out at the minimum and zoom-in at the maximum", () => {
    expect(canZoomOut(MIN_SCALE)).toBe(false);
    expect(canZoomIn(MIN_SCALE)).toBe(true);
    expect(canZoomIn(MAX_SCALE)).toBe(false);
    expect(canZoomOut(MAX_SCALE)).toBe(true);
  });

  it("allows both directions in the middle of the range", () => {
    expect(canZoomIn(4)).toBe(true);
    expect(canZoomOut(4)).toBe(true);
  });
});

describe("reset / identity", () => {
  it("exposes an identity transform that is already in-bounds", () => {
    expect(IDENTITY_TRANSFORM).toEqual({ scale: 1, tx: 0, ty: 0 });
    expect(clampTranslation(IDENTITY_TRANSFORM, SIZE)).toEqual(IDENTITY_TRANSFORM);
  });
});

describe("mapTransformToCss", () => {
  it("serializes to a translate+scale string with origin-0 semantics", () => {
    expect(mapTransformToCss({ scale: 2.5, tx: -120, ty: -40 })).toBe(
      "translate(-120px, -40px) scale(2.5)",
    );
  });
});
