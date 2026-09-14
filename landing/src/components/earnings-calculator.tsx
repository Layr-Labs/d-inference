"use client";

import { useState } from "react";
import {
  CALCULATOR_MODELS,
  HARDWARE_OPTIONS,
  MIN_PROVIDER_MEMORY_GB,
  DEFAULT_DUTY_CYCLE_PERCENT,
  calculateCapacityRevenue,
} from "../../earn-calculator-core";
import { CONSOLE_URL } from "../lib/links";
import { Arrow } from "./ui";

const macTypes = ["MacBook Pro", "Mac Mini", "Mac Studio", "Mac Pro"];
const initialHardware = HARDWARE_OPTIONS.find(
  (item) => item.id === "Mac Studio:M2 Ultra",
)!;
const dollars = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

export function EarningsCalculator() {
  const [hardware, setHardware] = useState(initialHardware);
  const [memory, setMemory] = useState(64);
  const [duty, setDuty] = useState(DEFAULT_DUTY_CYCLE_PERCENT);
  const [modelId, setModelId] = useState(CALCULATOR_MODELS[0].id);
  const model = CALCULATOR_MODELS.find((item) => item.id === modelId)!;
  const revenue =
    memory >= MIN_PROVIDER_MEMORY_GB
      ? calculateCapacityRevenue(model, hardware, memory, duty)
      : null;

  function selectHardware(id: string) {
    const selected = HARDWARE_OPTIONS.find((item) => item.id === id)!;
    setHardware(selected);
    setMemory(
      selected.ramOptions.includes(memory)
        ? memory
        : selected.ramOptions[selected.ramOptions.length - 1],
    );
  }

  return (
    <div className="calculator">
      <div className="calculator-heading">
        <span className="eyebrow">THE EARNINGS ESTIMATOR</span>
        <span className="small-label">01 / CONFIGURE</span>
      </div>
      <div className="calculator-fields">
        <label>
          Your Mac
          <select
            value={hardware.macType}
            onChange={(event) =>
              selectHardware(
                HARDWARE_OPTIONS.filter(
                  (item) => item.macType === event.target.value,
                ).at(-1)!.id,
              )
            }
          >
            {macTypes.map((type) => (
              <option key={type}>{type}</option>
            ))}
          </select>
        </label>
        <label>
          Chip
          <select
            value={hardware.id}
            onChange={(event) => selectHardware(event.target.value)}
          >
            {HARDWARE_OPTIONS.filter(
              (item) => item.macType === hardware.macType,
            ).map((item) => (
              <option key={item.id} value={item.id}>
                {item.chip}
              </option>
            ))}
          </select>
        </label>
        <label>
          Unified memory
          <select
            value={memory}
            onChange={(event) => setMemory(Number(event.target.value))}
          >
            {hardware.ramOptions.map((ram) => (
              <option key={ram} value={ram}>
                {ram} GB
              </option>
            ))}
          </select>
        </label>
        <label>
          Model
          <select
            value={modelId}
            onChange={(event) => setModelId(event.target.value)}
          >
            {CALCULATOR_MODELS.map((item) => (
              <option key={item.id} value={item.id}>
                {item.displayName}
              </option>
            ))}
          </select>
        </label>
      </div>
      <label className="duty-label" htmlFor="duty-cycle">
        Inference duty cycle <strong>{duty}%</strong>
      </label>
      <input
        id="duty-cycle"
        type="range"
        min="0"
        max="100"
        step="1"
        value={duty}
        onChange={(event) => setDuty(Number(event.target.value))}
      />
      <div className="range-labels">
        <span>0%</span>
        <span>Share of time actively generating tokens</span>
        <span>100%</span>
      </div>
      <div className="earnings-result" aria-live="polite" aria-atomic="true">
        <span className="small-label">ESTIMATED GROSS REVENUE</span>
        <p className="earnings-number">
          {revenue ? dollars.format(revenue.monthlyRevenueUSD) : "—"}
          <span>/ month</span>
        </p>
        <span className="earnings-detail">
          {revenue
            ? `${dollars.format(revenue.annualRevenueUSD)} / year · ${Math.round(revenue.decodeTokensPerSecond)} estimated tokens / sec`
            : memory < MIN_PROVIDER_MEMORY_GB
              ? "Providers require at least 48 GB of unified memory."
              : "Choose more memory to run this model."}
        </span>
      </div>
      <p className="calculator-note">
        Illustrative capacity estimate, not guaranteed income. Uses reference
        output-token prices and 65% memory-bandwidth efficiency. Demand, model
        availability, electricity, taxes, and fees affect actual earnings.
      </p>
      <a href={`${CONSOLE_URL}/earn`} className="button calculator-cta">
        Explore provider earnings <Arrow diagonal />
      </a>
    </div>
  );
}
