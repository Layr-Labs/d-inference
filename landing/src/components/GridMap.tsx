import type { CSSProperties } from "react";
import { GRID_CELL_HEIGHT, GRID_CELL_WIDTH, gridCells, storyCellIndex } from "../content/grid";

// The updated routed frame keeps only four blue reference points in the
// otherwise subdued map field (Figma 299:5352). These indices are tied to the
// authored grid data, so they stay attached through every camera transform.
const ROUTE_ACCENT_INDICES = new Set([264, 277, 280, 281]);

type GridMapProps = {
  className?: string;
  compact?: boolean;
  connected?: boolean;
  routing?: boolean;
  selectedCellIndex?: number | null;
};

export function GridMap({
  className = "",
  compact = false,
  connected = false,
  routing = false,
  selectedCellIndex = null,
}: GridMapProps) {
  return (
    <div
      className={`grid-map ${compact ? "grid-map--compact" : ""} ${routing ? "is-routing" : ""} ${connected ? "is-connected" : ""} ${className}`.trim()}
      aria-hidden="true"
    >
      {gridCells.map(([x, y, active], index) => {
        const ambientActivity = active && y <= 50;
        return (
          <i
            className={`${ambientActivity ? "is-active" : ""} ${ROUTE_ACCENT_INDICES.has(index) ? "is-route-accent" : ""} ${index === selectedCellIndex ? "is-target" : ""} ${index === storyCellIndex ? "is-story-target" : ""}`.trim()}
            key={index}
            style={
              {
                "--cell-x": `${x}%`,
                "--cell-y": `${y}%`,
                "--cell-w": `${GRID_CELL_WIDTH}%`,
                "--cell-h": `${GRID_CELL_HEIGHT}%`,
                "--flicker-duration": `${2600 + ((index * 137) % 2200)}ms`,
                "--flicker-delay": `-${(index * 347) % 4800}ms`,
                "--flicker-low": (0.42 + ((index * 11) % 22) / 100).toFixed(2),
                "--flicker-mid": (0.7 + ((index * 13) % 18) / 100).toFixed(2),
              } as CSSProperties
            }
          />
        );
      })}
    </div>
  );
}
