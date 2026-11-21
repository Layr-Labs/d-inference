import { createBlueprintRenderer } from '../blueprint/blueprintRenderer';
import { createPhotorealRenderer } from '../photoreal/photorealRenderer';
import type { ChipVariant } from '../variant';
import type { ChipRendererFactory } from './types';

export const RENDERERS: Record<ChipVariant, ChipRendererFactory> = {
  blueprint: createBlueprintRenderer,
  photoreal: createPhotorealRenderer,
};
