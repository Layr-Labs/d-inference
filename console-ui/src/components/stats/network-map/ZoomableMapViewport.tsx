"use client";

import { useEffect, useState, type CSSProperties, type ReactNode } from "react";
import { mapTransformToCss } from "./mapZoomMath";
import { useMapZoom } from "./useMapZoom";
import { MapZoomControls } from "./MapZoomControls";

const ANIMATE_TRANSITION = "transform 180ms ease-out";
/** How long the discoverability hint lingers before auto-fading. */
const HINT_VISIBLE_MS = 4200;

/** Live map state handed to the transformed children. */
export interface MapRenderContext {
  /** Current zoom scale (for `1/scale` counter-scaling and clustering). */
  scale: number;
  /** Container size in pixels (for screen-space work like clustering). */
  width: number;
  height: number;
  /** Animate a zoom toward a container-percentage point (cluster drill-in). */
  zoomToPercent: (xPct: number, yPct: number) => void;
}

interface ZoomableMapViewportProps {
  /** Classes for the clipping container (must include `relative overflow-hidden`). */
  className?: string;
  style?: CSSProperties;
  /** When false, no zoom/pan handlers, controls, or hint are wired (e.g. empty state). */
  interactive?: boolean;
  hint?: string;
  /** Fixed layer rendered behind the transform (e.g. grid background). */
  background?: ReactNode;
  /** Fixed layer rendered above the transform (e.g. legend pill). */
  overlay?: ReactNode;
  /** The pannable/zoomable layers; receives live map state for counter-scaling + clustering. */
  children: (context: MapRenderContext) => ReactNode;
}

function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return;
    const query = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setReduced(query.matches);
    update();
    query.addEventListener?.("change", update);
    return () => query.removeEventListener?.("change", update);
  }, []);
  return reduced;
}

/**
 * Thin viewport that turns any layered map into a zoom+pan surface.
 *
 * A single transform (`translate(tx, ty) scale(s)`, origin 0,0) is applied to a
 * wrapper holding the caller's layers, so geography and markers move together.
 * The grid `background`, the `overlay` legend, and the zoom controls/hint stay
 * outside that wrapper (fixed), and the current `scale` is handed to `children`
 * so SVG dots / HTML markers can counter-scale by `1/scale` to stay constant
 * size on screen.
 */
export function ZoomableMapViewport({
  className,
  style,
  interactive = true,
  hint = "scroll to zoom · drag to pan",
  background,
  overlay,
  children,
}: ZoomableMapViewportProps) {
  const {
    containerRef,
    transform,
    scale,
    size,
    isPanning,
    animate,
    interacted,
    canZoomIn,
    canZoomOut,
    zoomIn,
    zoomOut,
    reset,
    zoomToPercent,
    onPointerDown,
    onPointerMove,
    onPointerUp,
    onDoubleClick,
  } = useMapZoom(interactive);
  const reducedMotion = usePrefersReducedMotion();
  const [hintTimedOut, setHintTimedOut] = useState(false);

  useEffect(() => {
    if (!interactive) return;
    const timer = window.setTimeout(() => setHintTimedOut(true), HINT_VISIBLE_MS);
    return () => window.clearTimeout(timer);
  }, [interactive]);

  const showHint = interactive && !hintTimedOut && !interacted;
  const transition = animate && !reducedMotion ? ANIMATE_TRANSITION : "none";
  let cursor: CSSProperties["cursor"];
  if (interactive) cursor = isPanning ? "grabbing" : "grab";

  return (
    <div
      ref={containerRef}
      className={className}
      style={{ ...style, cursor, touchAction: interactive ? "none" : undefined }}
      onPointerDown={interactive ? onPointerDown : undefined}
      onPointerMove={interactive ? onPointerMove : undefined}
      onPointerUp={interactive ? onPointerUp : undefined}
      onPointerCancel={interactive ? onPointerUp : undefined}
      onDoubleClick={interactive ? onDoubleClick : undefined}
    >
      {background}
      <div
        className="absolute inset-0 select-none"
        style={{
          transform: mapTransformToCss(transform),
          transformOrigin: "0 0",
          transition,
          willChange: "transform",
        }}
      >
        {children({ scale, width: size.width, height: size.height, zoomToPercent })}
      </div>
      {overlay}
      {interactive && (
        <>
          <div
            aria-hidden={!showHint}
            className="pointer-events-none absolute bottom-4 left-4 z-30 rounded-md border border-border-dim bg-bg-primary/90 px-2.5 py-1 font-mono text-[10px] text-text-tertiary shadow-sm backdrop-blur"
            style={{
              opacity: showHint ? 1 : 0,
              transition: reducedMotion ? "none" : "opacity 600ms ease-out",
            }}
          >
            {hint}
          </div>
          <MapZoomControls
            scale={scale}
            canZoomIn={canZoomIn}
            canZoomOut={canZoomOut}
            onZoomIn={zoomIn}
            onZoomOut={zoomOut}
            onReset={reset}
          />
        </>
      )}
    </div>
  );
}
