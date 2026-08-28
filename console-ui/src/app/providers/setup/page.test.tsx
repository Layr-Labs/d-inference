// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProviderRequirementsState } from "../useProviderRequirements";
import ProviderSetupPage from "./page";

const requirementsMock = vi.hoisted(() => ({
  state: {
    status: "error",
    requirements: null,
  } as ProviderRequirementsState,
}));

vi.mock("../useProviderRequirements", () => ({
  useProviderRequirements: () => requirementsMock.state,
}));

describe("ProviderSetupPage hardware requirements", () => {
  beforeEach(() => {
    requirementsMock.state = { status: "error", requirements: null };
  });

  it("does not claim there is no floor when requirements are unavailable", () => {
    render(<ProviderSetupPage />);

    expect(
      screen.getByText(/Current onboarding requirements are temporarily unavailable/)
    ).toBeInTheDocument();
    expect(
      screen.queryByText(/currently has no stricter onboarding floor/)
    ).not.toBeInTheDocument();
    expect(screen.queryByText("darkbloom start")).not.toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent("Setup is paused");
  });

  it("links an enforced policy to availability registration", () => {
    requirementsMock.state = {
      status: "ready",
      requirements: {
        policy: {
          version: 9,
          mode: "enforce",
          min_memory_gb: 64,
          min_memory_bandwidth_gbs: 400,
          min_fp16_millitflops: 0,
          catalog_version: "apple-silicon-v1",
        },
        accepting_new_providers: true,
        grandfather_existing: true,
        metric_definitions: {},
      },
    };

    render(<ProviderSetupPage />);

    expect(screen.getByText(/New-machine policy v9 is enforce/)).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: "register hardware interest" })
    ).toHaveAttribute("href", "/provider-waitlist");
  });
});
