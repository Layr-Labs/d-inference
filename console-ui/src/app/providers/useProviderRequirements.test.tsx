// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { useProviderRequirements } from "./useProviderRequirements";

const { fetchRequirements } = vi.hoisted(() => ({
  fetchRequirements: vi.fn(),
}));

vi.mock("@/lib/api/provider-requirements", () => ({
  fetchProviderRequirements: fetchRequirements,
}));

function Probe() {
  const state = useProviderRequirements();
  return <p>{state.status}</p>;
}

describe("useProviderRequirements", () => {
  beforeEach(() => {
    fetchRequirements.mockReset();
  });

  it("retries one transient failure", async () => {
    fetchRequirements
      .mockRejectedValueOnce(new Error("temporary"))
      .mockResolvedValueOnce({
        policy: { mode: "enforce" },
        accepting_new_providers: true,
        grandfather_existing: true,
        metric_definitions: {},
      });

    render(<Probe />);

    expect(await screen.findByText("ready")).toBeInTheDocument();
    expect(fetchRequirements).toHaveBeenCalledTimes(2);
  });

  it("settles on an error after the bounded retry", async () => {
    fetchRequirements.mockRejectedValue(new Error("unavailable"));

    render(<Probe />);

    expect(await screen.findByText("error")).toBeInTheDocument();
    expect(fetchRequirements).toHaveBeenCalledTimes(2);
  });
});
