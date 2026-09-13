"use client";

import { Cpu } from "lucide-react";
import { DEFAULT_DUTY_CYCLE_PERCENT } from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

const selectClasses =
  "w-full bg-bg-tertiary rounded-lg px-3 py-2.5 text-sm text-text-primary " +
  "border border-border-dim focus:outline-none focus:ring-2 focus:ring-accent-brand/50 " +
  "cursor-pointer appearance-none";

/** The calculator remains hidden until all three hardware fields are chosen. */
export function HardwareSelector({ calc }: { calc: EarningsCalculator }) {
  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Cpu size={14} className="text-text-secondary" />
        <h3 className="text-sm font-medium text-text-primary">Your Mac</h3>
      </div>
      <p className="text-xs text-text-secondary mb-4">
        Choose your Mac model, chip family, and unified memory. Find these under{" "}
        <span className="font-medium text-text-primary">Apple menu &gt; About This Mac</span>.
      </p>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div>
          <label
            htmlFor="mac-type-select"
            className="block text-xs font-medium text-text-secondary uppercase tracking-wider mb-2"
          >
            Mac model
          </label>
          <select
            id="mac-type-select"
            value={calc.selectedMacType}
            onChange={(e) => calc.selectMacType(e.target.value)}
            className={selectClasses}
          >
            <option value="" disabled>
              Select model
            </option>
            {calc.macTypes.map((macType) => (
              <option key={macType} value={macType}>
                {macType}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label
            htmlFor="chip-select"
            className="block text-xs font-medium text-text-secondary uppercase tracking-wider mb-2"
          >
            Chip family
          </label>
          <select
            id="chip-select"
            value={calc.selectedChip}
            onChange={(e) => calc.selectChip(e.target.value)}
            disabled={!calc.selectedMacType}
            className={`${selectClasses} disabled:cursor-not-allowed disabled:opacity-50`}
          >
            <option value="" disabled>
              Select chip
            </option>
            {calc.availableChips.map((chip) => (
              <option key={chip} value={chip}>
                {chip}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label
            htmlFor="ram-select"
            className="block text-xs font-medium text-text-secondary uppercase tracking-wider mb-2"
          >
            Unified memory
          </label>
          <select
            id="ram-select"
            value={calc.selectedRAM ?? ""}
            onChange={(e) => calc.selectRAM(Number(e.target.value))}
            disabled={!calc.selectedChip}
            className={`${selectClasses} disabled:cursor-not-allowed disabled:opacity-50`}
          >
            <option value="" disabled>
              Select memory
            </option>
            {calc.availableRAM.map((ram) => (
              <option key={ram} value={ram}>
                {ram} GB
              </option>
            ))}
          </select>
        </div>
      </div>

      {calc.isProductionReady && (
        <div className="mt-5 border-t border-border-dim pt-5">
          <div className="flex items-center justify-between gap-4">
            <div>
              <label htmlFor="duty-cycle" className="text-sm font-medium text-text-primary">
                Duty cycle
              </label>
              <p className="mt-0.5 text-xs text-text-secondary">
                Share of time this Mac is producing output tokens.
              </p>
            </div>
            <output
              htmlFor="duty-cycle"
              className="shrink-0 rounded-md bg-bg-tertiary px-3 py-1.5 font-mono text-sm font-semibold text-text-primary"
            >
              {calc.dutyCyclePercent}%
            </output>
          </div>
          <input
            id="duty-cycle"
            type="range"
            min="5"
            max="100"
            step="5"
            value={calc.dutyCyclePercent}
            onChange={(event) => calc.selectDutyCyclePercent(Number(event.target.value))}
            className="mt-4 w-full accent-accent-brand"
          />
          <div className="mt-1 flex justify-between font-mono text-[10px] text-text-tertiary">
            <span>5%</span>
            <span>Default {DEFAULT_DUTY_CYCLE_PERCENT}%</span>
            <span>100%</span>
          </div>
        </div>
      )}
    </div>
  );
}
