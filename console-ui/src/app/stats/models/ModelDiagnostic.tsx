import { ModelCapacityCard } from "../ModelCapacityCard";
import { deprecatedModelLabel, modelDisplayName, plainModelDescription, type ActiveModelInventory } from "./model-inventory";

export function ModelDiagnostic({ item, capacityKnown }: { item: ActiveModelInventory; capacityKnown: boolean }) {
  const catalog = item.catalogModel;
  const capacity = item.capacity;
  return (
    <ModelCapacityCard
      id={item.id}
      displayName={modelDisplayName(item)}
      description={plainModelDescription(catalog)}
      statusLabel={deprecatedModelLabel(item.catalogStatus)}
      family={catalog?.family}
      quantization={catalog?.quantization}
      sizeGB={catalog?.sizeGB}
      minRAMGB={catalog?.minRAMGB}
      maxContextLength={catalog?.maxContextLength}
      totalNodes={item.providers}
      eligibleNodes={item.routable}
      hardwareNodes={item.hardware}
      fleetSharePct={item.sharePct}
      acceptingNodes={capacity?.routableProviders ?? (capacityKnown ? 0 : undefined)}
      warmNodes={capacity?.warmProviders}
      coldNodes={capacity?.coldProviders}
      activeRequests={capacity?.activeRequests}
      queuedRequests={capacity?.queuedRequests}
      queueLimit={capacity?.queueLimit}
      aggregateTPS={capacity?.aggregateTPS}
      estimatedTTFTMS={capacity?.estimatedTTFTMS}
      tokenBudgetRemaining={capacity?.tokenBudgetRemaining}
      tokenBudgetTotal={capacity?.tokenBudgetTotal}
      canAccept={capacity?.canAccept ?? (capacityKnown ? false : undefined)}
    />
  );
}
