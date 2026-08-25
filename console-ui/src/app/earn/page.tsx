"use client";

import { TopBar } from "@/components/TopBar";
import { useAuth } from "@/hooks/useAuth";
import { useEarningsCalculator } from "./useEarningsCalculator";
import { SetupProviderCTA } from "./SetupProviderCTA";
import { EarningsHero } from "./EarningsHero";
import { HardwareSelector } from "./HardwareSelector";
import { ModelSupportList } from "./ModelSupportList";
import { CalculationFlow } from "./CalculationFlow";
import { ProductionReadinessNotice } from "./ProductionReadinessNotice";

export default function EarnPage() {
  const { ready, authenticated, login } = useAuth();
  const calc = useEarningsCalculator();
  let calculatorContent = (
    <div className="rounded-xl border border-dashed border-border-dim bg-bg-secondary/50 px-6 py-10 mb-6 text-center">
      <p className="text-sm font-medium text-text-primary">Your estimate will appear here</p>
      <p className="mt-1 text-xs text-text-secondary">
        Select your Mac model, chip family, and unified memory above.
      </p>
    </div>
  );

  if (calc.isConfigured && !calc.isProductionReady) {
    calculatorContent = (
      <ProductionReadinessNotice
        calc={calc}
        authenticated={authenticated}
        ready={ready}
        login={login}
      />
    );
  } else if (calc.isProductionReady) {
    calculatorContent = (
      <>
        <EarningsHero
          calc={calc}
          authenticated={authenticated}
          ready={ready}
          login={login}
        />
        <SetupProviderCTA authenticated={authenticated} ready={ready} login={login} />
        <CalculationFlow calc={calc} />
        <ModelSupportList calc={calc} />
      </>
    );
  }

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Earnings Calculator" />

      <div className="flex-1 overflow-y-auto">
        {/* pb-24 keeps the floating avatar from covering content on mobile */}
        <div className="max-w-3xl mx-auto px-3 sm:px-6 py-6 sm:py-8 pb-24">
          <HardwareSelector calc={calc} />
          {calculatorContent}
        </div>
      </div>
    </div>
  );
}
