"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent, RefObject } from "react";
import {
  IDENTITY_TRANSFORM,
  canZoomIn,
  canZoomOut,
  clampTranslation,
  zoomAtPoint,
  type MapTransform,
  type ViewportSize,
} from "./mapZoomMath";

/** Multiplier applied per +/- button press and per double-click. */
const ZOOM_STEP = 1.6;
/** Multiplier applied when drilling into a cluster (a touch more aggressive). */
const CLUSTER_ZOOM_STEP = 2.4;
/** Wheel delta -> zoom factor sensitivity (factor = exp(-deltaY * k)). */
const WHEEL_ZOOM_SENSITIVITY = 0.0015;

interface DragState {
  pointerId: number;
  startX: number;
  startY: number;
  startTx: number;
  startTy: number;
}

export interface UseMapZoom {
  containerRef: RefObject<HTMLDivElement | null>;
  transform: MapTransform;
  scale: number;
  /** Live container size in pixels (for screen-space work like clustering). */
  size: ViewportSize;
  /** True while a pointer drag is panning the map. */
  isPanning: boolean;
  /** True when transform changes should animate (button/reset/double-click). */
  animate: boolean;
  /** Flips true the first time the user zooms or pans (for hint dismissal). */
  interacted: boolean;
  canZoomIn: boolean;
  canZoomOut: boolean;
  zoomIn: () => void;
  zoomOut: () => void;
  reset: () => void;
  /** Animate a zoom toward a container-percentage point (keeps it anchored). */
  zoomToPercent: (xPct: number, yPct: number, factor?: number) => void;
  onPointerDown: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onPointerMove: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onPointerUp: (event: ReactPointerEvent<HTMLDivElement>) => void;
  onDoubleClick: (event: ReactMouseEvent<HTMLDivElement>) => void;
}

/**
 * React state + event wiring around the pure {@link mapZoomMath} helpers.
 *
 * Container size is tracked with a ResizeObserver (cursor-anchored zoom and pan
 * clamping both need live pixel dimensions), and the wheel handler is attached
 * natively with `{ passive: false }` because React's synthetic `onWheel` is
 * passive and cannot call `preventDefault`. When `enabled` is false (e.g. the
 * empty map state) no listeners are attached and the transform stays identity.
 */
export function useMapZoom(enabled: boolean): UseMapZoom {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const sizeRef = useRef<ViewportSize>({ width: 0, height: 0 });
  const transformRef = useRef<MapTransform>(IDENTITY_TRANSFORM);
  const dragRef = useRef<DragState | null>(null);

  const [transform, setTransformState] = useState<MapTransform>(IDENTITY_TRANSFORM);
  const [size, setSize] = useState<ViewportSize>({ width: 0, height: 0 });
  const [isPanning, setIsPanning] = useState(false);
  const [animate, setAnimate] = useState(false);
  const [interacted, setInteracted] = useState(false);

  const applyTransform = useCallback((updater: (prev: MapTransform) => MapTransform) => {
    setTransformState((prev) => {
      const next = updater(prev);
      transformRef.current = next;
      return next;
    });
  }, []);

  const markInteracted = useCallback(() => {
    // useState bails out of a re-render when the value is unchanged.
    setInteracted(true);
  }, []);

  // Track container size and re-clamp the transform whenever it changes so an
  // in-bounds transform can never become out-of-bounds after a resize.
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const measure = (width: number, height: number) => {
      sizeRef.current = { width, height };
      setSize((prev) => (prev.width === width && prev.height === height ? prev : { width, height }));
      applyTransform((prev) => clampTranslation(prev, sizeRef.current));
    };
    const rect = el.getBoundingClientRect();
    measure(rect.width, rect.height);

    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver((entries) => {
      const contentRect = entries[0]?.contentRect;
      if (contentRect) measure(contentRect.width, contentRect.height);
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [applyTransform]);

  // Native, non-passive wheel listener so we can preventDefault page scroll.
  useEffect(() => {
    const el = containerRef.current;
    if (!el || !enabled) return;
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      const rect = el.getBoundingClientRect();
      const pointerX = event.clientX - rect.left;
      const pointerY = event.clientY - rect.top;
      const factor = Math.exp(-event.deltaY * WHEEL_ZOOM_SENSITIVITY);
      setAnimate(false);
      applyTransform((prev) => zoomAtPoint(prev, pointerX, pointerY, factor, sizeRef.current));
      markInteracted();
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, [enabled, applyTransform, markInteracted]);

  // Snap back to the original framing when interactions are switched off.
  useEffect(() => {
    if (enabled) return;
    dragRef.current = null;
    setIsPanning(false);
    setAnimate(false);
    applyTransform(() => IDENTITY_TRANSFORM);
  }, [enabled, applyTransform]);

  const zoomByFactor = useCallback(
    (factor: number) => {
      const { width, height } = sizeRef.current;
      setAnimate(true);
      applyTransform((prev) => zoomAtPoint(prev, width / 2, height / 2, factor, sizeRef.current));
      markInteracted();
    },
    [applyTransform, markInteracted],
  );

  const zoomIn = useCallback(() => zoomByFactor(ZOOM_STEP), [zoomByFactor]);
  const zoomOut = useCallback(() => zoomByFactor(1 / ZOOM_STEP), [zoomByFactor]);

  const reset = useCallback(() => {
    setAnimate(true);
    applyTransform(() => IDENTITY_TRANSFORM);
    markInteracted();
  }, [applyTransform, markInteracted]);

  const zoomToPercent = useCallback(
    (xPct: number, yPct: number, factor: number = CLUSTER_ZOOM_STEP) => {
      const { width, height } = sizeRef.current;
      const current = transformRef.current;
      // Anchor the point's *current* screen position so the cluster stays put
      // while neighbors fan out around it.
      const screenX = (xPct / 100) * width * current.scale + current.tx;
      const screenY = (yPct / 100) * height * current.scale + current.ty;
      setAnimate(true);
      applyTransform((prev) => zoomAtPoint(prev, screenX, screenY, factor, sizeRef.current));
      markInteracted();
    },
    [applyTransform, markInteracted],
  );

  const onPointerDown = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      if (!enabled || event.button !== 0) return;
      const el = containerRef.current;
      if (!el) return;
      el.setPointerCapture?.(event.pointerId);
      const current = transformRef.current;
      dragRef.current = {
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        startTx: current.tx,
        startTy: current.ty,
      };
      setIsPanning(true);
      setAnimate(false);
      markInteracted();
    },
    [enabled, markInteracted],
  );

  const onPointerMove = useCallback(
    (event: ReactPointerEvent<HTMLDivElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      const dx = event.clientX - drag.startX;
      const dy = event.clientY - drag.startY;
      applyTransform((prev) =>
        clampTranslation({ scale: prev.scale, tx: drag.startTx + dx, ty: drag.startTy + dy }, sizeRef.current),
      );
    },
    [applyTransform],
  );

  const onPointerUp = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current;
    if (!drag || drag.pointerId !== event.pointerId) return;
    dragRef.current = null;
    setIsPanning(false);
    containerRef.current?.releasePointerCapture?.(event.pointerId);
  }, []);

  const onDoubleClick = useCallback(
    (event: ReactMouseEvent<HTMLDivElement>) => {
      if (!enabled) return;
      const el = containerRef.current;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      const pointerX = event.clientX - rect.left;
      const pointerY = event.clientY - rect.top;
      setAnimate(true);
      applyTransform((prev) => zoomAtPoint(prev, pointerX, pointerY, ZOOM_STEP, sizeRef.current));
      markInteracted();
    },
    [enabled, applyTransform, markInteracted],
  );

  return {
    containerRef,
    transform,
    scale: transform.scale,
    size,
    isPanning,
    animate,
    interacted,
    canZoomIn: canZoomIn(transform.scale),
    canZoomOut: canZoomOut(transform.scale),
    zoomIn,
    zoomOut,
    reset,
    zoomToPercent,
    onPointerDown,
    onPointerMove,
    onPointerUp,
    onDoubleClick,
  };
}
