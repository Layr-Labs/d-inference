"use client";

import { Cpu } from "lucide-react";
import type { EarningsCalculator } from "./useEarningsCalculator";

const selectClasses =
  "w-full bg-bg-tertiary rounded-lg px-3 py-2.5 text-sm text-text-primary " +
  "border border-border-dim focus:outline-none focus:ring-2 focus:ring-accent-brand/50 " +
  "cursor-pointer appearance-none";

/**
 * The calculator's only two inputs: exact Mac/chip profile + unified memory.
 * Everything else (full-month availability and electricity rate) is fixed and
 * stated in the assumptions.
 */
export function HardwareSelector({ calc }: { calc: EarningsCalculator }) {
  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Cpu size={14} className="text-text-secondary" />
        <h3 className="text-sm font-medium text-text-primary">Your Mac</h3>
      </div>
      <p className="text-xs text-text-secondary mb-4">
        Find both under <span className="font-medium text-text-primary"> &gt; About This Mac</span>.
      </p>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label
            htmlFor="hardware-select"
            className="block text-xs font-medium text-text-secondary uppercase tracking-wider mb-2"
          >
            Mac model and chip
          </label>
          <select
            id="hardware-select"
            value={calc.selectedHardwareID}
            onChange={(e) => calc.selectHardware(e.target.value)}
            className={selectClasses}
          >
            {calc.hardwareOptions.map((option) => (
              <option key={option.id} value={option.id}>
                {option.macType} · Apple {option.chip}
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
            value={calc.effectiveRAM}
            onChange={(e) => calc.selectRAM(Number(e.target.value))}
            className={selectClasses}
          >
            {calc.availableRAM.map((ram) => (
              <option key={ram} value={ram}>
                {ram} GB
              </option>
            ))}
          </select>
        </div>
      </div>
    </div>
  );
}
