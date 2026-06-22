"use client";

import { Cpu, Info } from "lucide-react";
import { MAC_TYPES, type MacConfig } from "./calc";
import { PillButton } from "./PillButton";
import type { EarningsCalculator } from "./useEarningsCalculator";

export function HardwareSelector({
  calc,
  config,
}: {
  calc: EarningsCalculator;
  config: MacConfig;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-5">
        <Cpu size={14} className="text-text-tertiary" />
        <h3 className="text-sm font-medium text-text-primary">Select Your Hardware</h3>
      </div>

      <div className="mb-5">
        <p className="text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
          1. Mac Type
        </p>
        <div className="flex flex-wrap gap-2">
          {MAC_TYPES.map((mt) => (
            <PillButton
              key={mt}
              label={mt}
              selected={calc.selectedMacType === mt}
              onClick={() => calc.selectMacType(mt)}
            />
          ))}
        </div>
      </div>

      <div className="mb-5">
        <p className="text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
          2. Chip
        </p>
        <div className="flex flex-wrap gap-2">
          {calc.availableChips.map((chip) => (
            <PillButton
              key={chip}
              label={chip}
              selected={calc.effectiveChip === chip}
              onClick={() => calc.selectChip(chip)}
            />
          ))}
        </div>
      </div>

      <div className="mb-5">
        <p className="text-xs font-medium text-text-tertiary uppercase tracking-wider mb-3">
          3. Memory
        </p>
        <div className="flex flex-wrap gap-2">
          {calc.availableRAM.map((ram) => (
            <PillButton
              key={ram}
              label={`${ram} GB`}
              selected={calc.effectiveRAM === ram}
              onClick={() => calc.selectRAM(ram)}
            />
          ))}
        </div>
      </div>

      <div className="flex items-start gap-2 px-3 py-2.5 rounded-lg bg-bg-tertiary">
        <Info size={14} className="text-text-tertiary shrink-0 mt-0.5" />
        <p className="text-xs text-text-tertiary">
          Not sure about your specs? Click{" "}
          <span className="font-medium text-text-secondary"> &gt; About This Mac</span>{" "}
          to check.
        </p>
      </div>

      <div className="mt-4 flex flex-wrap gap-2">
        <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-secondary">
          {calc.selectedMacType}
        </span>
        <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-secondary">
          {calc.effectiveChip}
        </span>
        <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-secondary">
          {calc.effectiveRAM} GB
        </span>
        <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-tertiary">
          {config.bandwidthGBs} GB/s
        </span>
        <span className="px-2.5 py-1 rounded bg-bg-elevated text-xs font-mono text-text-tertiary">
          {config.idleWatts}W idle → {config.inferWatts}W infer
        </span>
      </div>
    </div>
  );
}
