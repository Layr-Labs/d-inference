import type { Rect } from '../geometry';
import { createLayer, type Layer } from '../render/canvas';
import type { ChipScene } from '../render/types';
import { createBrush } from './brush';
import { buildEmissive, type Emissive } from './emissive';
import { rectPath } from './glow';
import { fitLayout } from './layoutFit';
import { buildLightKit, type LightKit } from './lightKit';
import { glowColors, materials, type Glow } from './materials';
import { dieRadius } from './paintDie';
import { packageRadius } from './paintPackages';
import { paintStatic } from './paintStatic';
import { substrateRadius } from './paintSubstrate';
import type { Textures } from './textures';

/** Everything the frame pass composites, rebuilt whenever the scene changes. */
export interface PhotorealScene {
  scene: ChipScene;
  base: Layer;
  emissive: Emissive;
  kit: LightKit;
  glow: Glow;
  /** The substrate outline: confines power-off dimming, and light spill in light theme. */
  chip: Path2D;
  /** Polished surfaces that catch the specular sweep: dies and memory package tops. */
  gloss: Path2D;
  gpuBlocks: Rect[];
}

/** Share of the canvas the package fills, leaving a margin for its shadow and glow. */
const FIT = 0.94;

export function buildScene(shared: ChipScene, tex: Textures): PhotorealScene | null {
  const scene = { ...shared, layout: fitLayout(shared.layout, FIT) },
    { layout, palette, dpr } = scene,
    { unit } = layout,
    base = createLayer(layout.width, layout.height, dpr);
  if (!base) return null;
  const mats = materials(palette),
    glow = glowColors(palette),
    gloss = new Path2D();
  paintStatic(createBrush(base.ctx, dpr, unit, mats, tex), scene);
  for (const die of layout.dies) rectPath(die, dieRadius(unit), gloss);
  for (const pkg of layout.memory) rectPath(pkg, packageRadius(unit), gloss);
  return {
    scene,
    base,
    emissive: buildEmissive(scene, mats, glow, tex),
    kit: buildLightKit(glow, layout.memory[0]?.cells[0] ?? null, dpr),
    glow,
    chip: rectPath(layout.substrate, substrateRadius(unit)),
    gloss,
    gpuBlocks: layout.blocks.filter((block) => block.kind === 'gpu').map((block) => block.body),
  };
}

/** Frees the large backing stores now instead of whenever the collector gets to them. */
export function releaseScene(built: PhotorealScene | null) {
  if (!built) return;
  built.base.canvas.width = built.base.canvas.height = 0;
  const { atlas } = built.emissive;
  if (atlas) atlas.width = atlas.height = 0;
}
