import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import {
  ByMachineList,
  machineLabel,
  machineId,
  type MachineEarnings,
} from "@/app/providers/earnings/ByMachineList";

const machine = (overrides: Partial<MachineEarnings>): MachineEarnings => ({
  provider_key: "k".repeat(44),
  total_micro_usd: 1_500_000,
  total_usd: "1.500000",
  job_count: 42,
  prompt_tokens: 1000,
  completion_tokens: 500,
  last_earned_at: "2026-09-10T12:00:00Z",
  ...overrides,
});

describe("machineLabel / machineId", () => {
  it("uses chip and memory when known", () => {
    expect(machineLabel(machine({ chip_name: "Apple M4 Max", memory_gb: 64 }))).toBe(
      "Apple M4 Max · 64 GB",
    );
  });

  it("falls back to a generic label without hardware info", () => {
    expect(machineLabel(machine({}))).toBe("Machine");
  });

  it("labels the empty key as Other with no ID", () => {
    expect(machineLabel(machine({ provider_key: "" }))).toBe("Other");
    expect(machineId(machine({ provider_key: "" }))).toBe("");
  });

  it("derives the ID from the stable key tail", () => {
    expect(machineId(machine({ provider_key: "abcdef123456" }))).toBe("ID …123456");
  });
});

describe("ByMachineList", () => {
  it("shows every machine with an always-visible ID", () => {
    render(
      <ByMachineList
        machines={[
          machine({ provider_key: "key-one-aaaaaa", chip_name: "Apple M4 Max", memory_gb: 64 }),
          machine({
            provider_key: "key-two-dddddd",
            chip_name: "Apple M4 Max",
            memory_gb: 64,
            total_usd: "0.250000",
          }),
        ]}
      />,
    );
    // Identical hardware stays distinguishable because the ID is always shown.
    expect(screen.getAllByText("Apple M4 Max · 64 GB")).toHaveLength(2);
    expect(screen.getByText("ID …aaaaaa")).toBeTruthy();
    expect(screen.getByText("ID …dddddd")).toBeTruthy();
    expect(screen.getByText("$1.500000")).toBeTruthy();
    expect(screen.getByText("$0.250000")).toBeTruthy();
    // "Last earned" was cut deliberately — it read as "last active" but only
    // reflected earnings rows, going stale for online-but-idle machines.
    expect(screen.queryByText("Last active")).toBeNull();
  });

  it("shows the unattributed bucket as Other with an explainer", () => {
    render(<ByMachineList machines={[machine({ provider_key: "" })]} />);
    expect(screen.getByText("Other")).toBeTruthy();
    expect(screen.getByText(/not attributed to a machine/)).toBeTruthy();
  });

  it("renders nothing when there are no machines", () => {
    const { container } = render(<ByMachineList machines={[]} />);
    expect(container.innerHTML).toBe("");
  });
});
