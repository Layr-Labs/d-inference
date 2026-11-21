import type { ChipAnatomy } from '../anatomy';
import type { Point } from '../geometry';
import type { HardwareLight } from '../hardware/drive';
import type { ChipLayout } from '../layout';
import type { MemoryMap } from '../memoryMap';
import type { ChipPalette } from '../palette';
import type { WorkloadFrame } from '../workload/types';

/** Everything that changes rarely; renderers rebuild their static layers when it changes. */
export interface ChipScene {
  anatomy: ChipAnatomy;
  layout: ChipLayout;
  memory: MemoryMap;
  palette: ChipPalette;
  /** Device pixel ratio of the canvas backing store. */
  dpr: number;
}
export interface RenderFrame {
  /** Live allocations and counts, or an explicit synthetic preview. */
  workload: WorkloadFrame;
  /** Fresh eased hardware measurements, or null when unavailable. */
  hardware: HardwareLight | null;
  /** False under prefers-reduced-motion: draw steady levels, no sweeps, pulses or shimmer. */
  motion: boolean;
  /** Pointer over the stage in [-1, 1] on both axes, or null when it is elsewhere. */
  pointer: Point | null;
}
export interface ChipRenderer {
  setScene(scene: ChipScene): void;
  draw(frame: RenderFrame): void;
  dispose(): void;
}
export type ChipRendererFactory = (ctx: CanvasRenderingContext2D) => ChipRenderer;
