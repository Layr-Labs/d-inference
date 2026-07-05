"use client";

import { Maximize2, Minus, Plus } from "lucide-react";

interface MapZoomControlsProps {
  scale: number;
  canZoomIn: boolean;
  canZoomOut: boolean;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onReset: () => void;
}

const BUTTON_CLASS =
  "flex h-7 w-7 items-center justify-center text-text-secondary transition-colors hover:bg-bg-hover hover:text-text-primary disabled:pointer-events-none disabled:opacity-35 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-accent-brand";

/**
 * Glassy bottom-right zoom cluster: zoom in / out / reset plus a live zoom
 * readout. Styled to match the map legend pill; buttons are keyboard-focusable
 * and disable themselves at the clamp limits.
 */
export function MapZoomControls({
  scale,
  canZoomIn,
  canZoomOut,
  onZoomIn,
  onZoomOut,
  onReset,
}: MapZoomControlsProps) {
  return (
    <div className="absolute bottom-4 right-4 z-30 flex flex-col overflow-hidden rounded-lg border border-border-dim bg-bg-primary/90 shadow-sm backdrop-blur">
      <button
        type="button"
        aria-label="Zoom in"
        disabled={!canZoomIn}
        onClick={onZoomIn}
        className={BUTTON_CLASS}
      >
        <Plus size={14} />
      </button>
      <div className="h-px bg-border-dim" />
      <button
        type="button"
        aria-label="Zoom out"
        disabled={!canZoomOut}
        onClick={onZoomOut}
        className={BUTTON_CLASS}
      >
        <Minus size={14} />
      </button>
      <div className="h-px bg-border-dim" />
      <button
        type="button"
        aria-label="Reset map view"
        onClick={onReset}
        className={BUTTON_CLASS}
      >
        <Maximize2 size={13} />
      </button>
      <div className="h-px bg-border-dim" />
      <span
        aria-hidden="true"
        className="select-none px-1 py-1 text-center font-mono text-[10px] tabular-nums text-text-tertiary"
      >
        {scale.toFixed(1)}×
      </span>
    </div>
  );
}
