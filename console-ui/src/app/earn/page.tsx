"use client";

import { TopBar } from "@/components/TopBar";
import { useAuth } from "@/hooks/useAuth";
import { useProviderRequirements } from "../providers/useProviderRequirements";
import { CalculationFlow } from "./CalculationFlow";
import { EarningsHero } from "./EarningsHero";
import { HardwareSelector } from "./HardwareSelector";
import { ModelSupportList } from "./ModelSupportList";
import { ProductionReadinessNotice } from "./ProductionReadinessNotice";
import {
  ProviderAdmissionNotice,
  selectedHardwareIsBlocked,
} from "./ProviderAdmissionNotice";
import { SetupProviderCTA } from "./SetupProviderCTA";
import { useEarningsCalculator } from "./useEarningsCalculator";

export default function EarnPage() {
  const { ready, authenticated, login } = useAuth();
  const calc = useEarningsCalculator();
  const providerRequirements = useProviderRequirements();
  const setupBlocked = selectedHardwareIsBlocked(calc, providerRequirements);

  let calculatorContent = (
    <div className="mb-6 rounded-xl border border-dashed border-border-dim bg-bg-secondary/50 px-6 py-10 text-center">
      <p className="text-sm font-medium text-text-primary">
        Your estimate will appear here
      </p>
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
        {!setupBlocked && (
          <SetupProviderCTA
            authenticated={authenticated}
            ready={ready}
            login={login}
          />
        )}
        <CalculationFlow calc={calc} />
        <ModelSupportList calc={calc} />
      </>
    );
  }

  return (
    <div className="flex h-full flex-col">
      <TopBar title="Earnings Calculator" />

      <div className="flex-1 overflow-y-auto">
        <div className="mx-auto max-w-3xl px-3 py-6 pb-24 sm:px-6 sm:py-8">
          <HardwareSelector calc={calc} />
          {calc.isConfigured && (
            <ProviderAdmissionNotice
              calc={calc}
              requirementsState={providerRequirements}
            />
          )}
          {calculatorContent}
        </div>
      </div>
    </div>
  );
}
