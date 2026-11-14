import type { ChipScene } from '../render/types';
import type { Brush } from './brush';
import { paintCapacitors } from './paintCapacitors';
import { paintDies } from './paintDie';
import { paintPackages } from './paintPackages';
import { paintStage } from './paintStage';
import { paintSubstrate } from './paintSubstrate';
import { capacitorLayout, viaLayout } from './substrateLayout';

/** Everything that does not move: painted once per size, theme, model set and pixel ratio. */
export function paintStatic(brush: Brush, scene: ChipScene) {
  const { layout, anatomy, palette } = scene,
    caps = capacitorLayout(layout);
  brush.ctx.clearRect(0, 0, layout.width, layout.height);
  paintStage(brush, layout.substrate, layout.width, layout.height);
  paintSubstrate(brush, layout, viaLayout(layout, caps));
  paintCapacitors(brush, caps);
  paintPackages(brush, layout, anatomy.memoryGb, palette.font);
  paintDies(brush, layout);
}
