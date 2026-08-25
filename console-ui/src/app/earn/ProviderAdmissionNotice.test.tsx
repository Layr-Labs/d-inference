// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { ProviderRequirementsState } from "../providers/useProviderRequirements";
import {
  ProviderAdmissionNotice,
  selectedHardwareIsBlocked,
} from "./ProviderAdmissionNotice";
import type { EarningsCalculator } from "./useEarningsCalculator";

const calc = {
  selectedChip: "M4",
  effectiveRAM: 16,
  hardware: { bandwidthGBs: 120 },
} as EarningsCalculator;

function state(
  mode: "disabled" | "shadow" | "enforce",
  minMemoryGB = 0
): ProviderRequirementsState {
  return {
    status: "ready",
    requirements: {
      policy: {
        version: 7,
        mode,
        min_memory_gb: minMemoryGB,
        min_memory_bandwidth_gbs: 0,
        min_fp16_millitflops: 0,
        catalog_version: "apple-silicon-v1",
      },
      accepting_new_providers: true,
      grandfather_existing: true,
      metric_definitions: {},
    },
  };
}

describe("ProviderAdmissionNotice", () => {
  it("routes a configuration below the enforced memory floor to the waitlist", () => {
    expect(selectedHardwareIsBlocked(calc, state("enforce", 32))).toBe(true);
    render(
      <ProviderAdmissionNotice
        calc={calc}
        requirementsState={state("enforce", 32)}
      />
    );

    expect(
      screen.getByText("This Mac is below the current new-provider memory floor")
    ).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: "Register this Mac's hardware interest" })
    ).toHaveAttribute(
      "href",
      "/provider-waitlist?chip=M4&memory_gb=16"
    );
  });

  it("blocks setup when the selected chip is below the bandwidth floor", () => {
    const requirements = state("enforce");
    requirements.requirements!.policy.min_memory_bandwidth_gbs = 200;
    expect(selectedHardwareIsBlocked(calc, requirements)).toBe(true);
  });

  it("does not imply approval when requirements are unavailable", () => {
    const unavailable: ProviderRequirementsState = {
      status: "error",
      requirements: null,
    };
    expect(selectedHardwareIsBlocked(calc, unavailable)).toBe(true);
    render(
      <ProviderAdmissionNotice
        calc={calc}
        requirementsState={unavailable}
      />
    );

    expect(screen.getByRole("alert")).toHaveTextContent(
      "not provider admission approval"
    );
    expect(
      screen.getByRole("link", { name: "Open hardware interest registration" })
    ).toHaveAttribute(
      "href",
      "/provider-waitlist?chip=M4&memory_gb=16"
    );
  });

  it("stays hidden when new-machine enforcement is disabled", () => {
    const { container } = render(
      <ProviderAdmissionNotice
        calc={calc}
        requirementsState={state("disabled")}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });
});
