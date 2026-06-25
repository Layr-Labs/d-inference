/**
 * Pure, DOM-free transform math for the zoomable network map.
 *
 * The viewport applies a single CSS transform — `translate(tx, ty) scale(s)`
 * with `transform-origin: 0 0` — to a layer that fills the container. A point
 * `(px, py)` in the layer's unscaled local coordinates therefore lands on screen
 * at `(px * s + tx, py * s + ty)`. Every helper below is a pure function of a
 * `MapTransform` plus, where relevant, the container `ViewportSize`, so the whole
 * module is trivially unit-testable.
 */

export interface MapTransform {
  /** Zoom factor, clamped to [MIN_SCALE, MAX_SCALE]. */
  scale: number;
  /** Horizontal translation in container pixels. */
  tx: number;
  /** Vertical translation in container pixels. */
  ty: number;
}

export interface ViewportSize {
  width: number;
  height: number;
}

export const MIN_SCALE = 1;
export const MAX_SCALE = 8;

/** At scale 1 the map sits at its original framing with no translation. */
export const IDENTITY_TRANSFORM: MapTransform = { scale: MIN_SCALE, tx: 0, ty: 0 };

/** Hysteresis used to disable the +/- controls at the clamp limits. */
export const SCALE_EPSILON = 0.01;

function clampNumber(value: number, min: number, max: number): number {
  if (Number.isNaN(value)) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

/** Collapse `-0` to `0` so transforms serialize cleanly and compare strictly. */
function normalizeZero(value: number): number {
  return value === 0 ? 0 : value;
}

function safeSize(size: ViewportSize): ViewportSize {
  return {
    width: Number.isFinite(size.width) ? Math.max(0, size.width) : 0,
    height: Number.isFinite(size.height) ? Math.max(0, size.height) : 0,
  };
}

/** Clamp a raw scale into the supported zoom range. */
export function clampScale(scale: number): number {
  return clampNumber(scale, MIN_SCALE, MAX_SCALE);
}

/**
 * Clamp translation so the scaled layer always fully covers the container — the
 * map can never be dragged far enough to expose an empty gap. The scaled layer
 * spans `width * s` x `height * s` from its top-left at `(tx, ty)`, so:
 *   - left edge must stay <= 0          => tx <= 0
 *   - right edge must stay >= width     => tx >= width * (1 - s)
 * and symmetrically for the vertical axis. At scale 1 this forces `tx = ty = 0`.
 */
export function clampTranslation(transform: MapTransform, size: ViewportSize): MapTransform {
  const scale = clampScale(transform.scale);
  const { width, height } = safeSize(size);
  const minTx = width * (1 - scale);
  const minTy = height * (1 - scale);
  return {
    scale,
    tx: normalizeZero(clampNumber(transform.tx, minTx, 0)),
    ty: normalizeZero(clampNumber(transform.ty, minTy, 0)),
  };
}

/**
 * Zoom by `factor` while keeping the local point under `(pointerX, pointerY)`
 * (container-relative pixels) stationary on screen. Scale is clamped first, so
 * the effective ratio reflects the real (post-clamp) change, and the result is
 * pan-clamped to keep the layer covering the container.
 */
export function zoomAtPoint(
  transform: MapTransform,
  pointerX: number,
  pointerY: number,
  factor: number,
  size: ViewportSize,
): MapTransform {
  const currentScale = clampScale(transform.scale);
  const nextScale = clampScale(currentScale * factor);
  const ratio = currentScale === 0 ? 1 : nextScale / currentScale;
  const tx = pointerX - (pointerX - transform.tx) * ratio;
  const ty = pointerY - (pointerY - transform.ty) * ratio;
  return clampTranslation({ scale: nextScale, tx, ty }, size);
}

/** True when the map can still zoom further in (controls/UI gating). */
export function canZoomIn(scale: number): boolean {
  return clampScale(scale) < MAX_SCALE - SCALE_EPSILON;
}

/** True when the map can still zoom further out (controls/UI gating). */
export function canZoomOut(scale: number): boolean {
  return clampScale(scale) > MIN_SCALE + SCALE_EPSILON;
}

/** Serialize a transform into the CSS string consumed by the viewport layer. */
export function mapTransformToCss(transform: MapTransform): string {
  return `translate(${transform.tx}px, ${transform.ty}px) scale(${transform.scale})`;
}
