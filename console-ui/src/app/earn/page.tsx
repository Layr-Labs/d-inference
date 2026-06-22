"use client";

import { TopBar } from "@/components/TopBar";
import { useAuth } from "@/hooks/useAuth";
import { ASSUMED_UTILIZATION, CONTINUOUS_BATCH_FACTOR } from "./calc";
import { useEarningsCalculator } from "./useEarningsCalculator";
import { SetupProviderCTA } from "./SetupProviderCTA";
import { HardwareSelector } from "./HardwareSelector";
import { ModelSelector } from "./ModelSelector";
import { EarningsResults } from "./EarningsResults";

export default function EarnPage() {
  const { ready, authenticated, login } = useAuth();
  const calc = useEarningsCalculator();

  if (!calc.selectedConfig) return null;
  const config = calc.selectedConfig;

  return (
    <div className="flex flex-col h-full">
      <TopBar title="Earnings Calculator" />

      <div className="flex-1 overflow-y-auto">
        <div className="max-w-4xl mx-auto px-3 sm:px-6 py-6 sm:py-8">
          {/* Header */}
          <div className="mb-8">
            <h2 className="text-lg font-semibold text-text-primary mb-1">
              Provider Earnings Calculator
            </h2>
            <p className="text-sm text-text-tertiary">
              Estimate how much your Apple Silicon Mac can earn serving inference
              on the Darkbloom network — usage earnings plus the base-reward floor.
            </p>
          </div>

          <SetupProviderCTA authenticated={authenticated} ready={ready} login={login} />
          <HardwareSelector calc={calc} config={config} />
          <ModelSelector calc={calc} />
          <EarningsResults calc={calc} config={config} />

          {/* Disclaimer */}
          <div className="rounded-xl bg-bg-secondary p-5 mb-8">
            <p className="text-xs text-text-tertiary mb-2">
              <span className="font-medium text-text-secondary">These are estimates only.</span> Usage earnings assume {Math.round(ASSUMED_UTILIZATION * 100)}% utilization with continuous batching ({CONTINUOUS_BATCH_FACTOR}× concurrent requests); actual usage depends on network demand, model popularity, your provider reputation, and how many other providers serve the same model. The live network currently runs well below this.
            </p>
            <p className="text-xs text-text-tertiary mb-2">
              <span className="font-medium text-text-secondary">Base rewards</span> are paid on top of usage to attested machines that stay online ≥90% of each 5-minute settlement period, up to a fixed monthly budget — they are not a guarantee.
            </p>
            <p className="text-xs text-text-tertiary">
              When your Mac is idle (no requests), it draws minimal power — the electricity cost shown only applies during active inference. You keep 100% of both usage revenue and base rewards.
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
