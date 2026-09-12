import { calculateModelAvailability } from "../model-capacity";
import type { ActiveModelInventory } from "./model-inventory";

/** Keep every model presentation on the same unknown-versus-zero contract. */
export function modelAvailability(item: ActiveModelInventory, capacityKnown: boolean) {
  return calculateModelAvailability(
    item.providers,
    item.routable,
    item.capacity?.routableProviders ?? (capacityKnown ? 0 : undefined),
  );
}
