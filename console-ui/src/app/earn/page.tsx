"use client";

import { TopBar } from "@/components/TopBar";
import { useAuth } from "@/hooks/useAuth";
import { BaseRewardsPanel } from "@/components/earn/BaseRewardsPanel";
import { useEarningsCalculator } from "./useEarningsCalculator";
import { SetupProviderCTA } from "./SetupProviderCTA";
import { EarningsHero } from "./EarningsHero";
import { HardwareSelector } from "./HardwareSelector";
import { ModelSupportList } from "./ModelSupportList";
import { AssumptionsPanel } from "./AssumptionsPanel";

export default function EarnPage() {
  const { ready, authenticated, login } = useAuth();
  const calc = useEarningsCalculator();

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Earnings Calculator" />

      <div className="flex-1 overflow-y-auto">
        {/* pb-24 keeps the floating avatar from covering content on mobile */}
        <div className="max-w-3xl mx-auto px-3 sm:px-6 py-6 sm:py-8 pb-24">
          <p className="text-sm text-text-secondary mb-6">
            Estimate a capacity share of the network&apos;s trailing settled work, with power
            and capped base-reward policy shown separately.
          </p>

          <EarningsHero calc={calc} authenticated={authenticated} ready={ready} login={login} />
          <HardwareSelector calc={calc} />
          <ModelSupportList calc={calc} />
          <BaseRewardsPanel policy={calc.market?.base_rewards ?? null} state={calc.marketState} />
          <AssumptionsPanel calc={calc} />
          <SetupProviderCTA authenticated={authenticated} ready={ready} login={login} />
        </div>
      </div>
    </div>
  );
}
