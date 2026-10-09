// @vitest-environment jsdom
import { describe, it, expect, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import { MachineCard } from "./MachineCard";
import { makeProvider } from "./testFixtures";
import type { RoutingCtx } from "./routing";

// The Remove button has its own behavioral test; here we only assert MachineCard
// gates the affordance by status, so stub the button to a marker.
vi.mock("./RemoveMachineButton", () => ({
  RemoveMachineButton: () => <div data-testid="remove-affordance" />,
}));

const ctx: RoutingCtx = {
  latest_provider_version: "0.6.5",
  min_provider_version: "0.6.0",
  heartbeat_timeout_seconds: 90,
  challenge_max_age_seconds: 360,
};

const AFFORDANCE = "remove-affordance";

describe("MachineCard remove gating", () => {
  it("shows the Remove affordance for an offline machine", () => {
    render(<MachineCard provider={makeProvider({ status: "offline" })} ctx={ctx} fleetMaxDecodeTps={100} />);
    expect(screen.getByTestId(AFFORDANCE)).toBeInTheDocument();
  });

  it("shows the Remove affordance for a never-seen machine", () => {
    render(<MachineCard provider={makeProvider({ status: "never_seen" })} ctx={ctx} fleetMaxDecodeTps={100} />);
    expect(screen.getByTestId(AFFORDANCE)).toBeInTheDocument();
  });

  it("hides the Remove affordance for an online/serving machine", () => {
    render(
      <MachineCard
        provider={makeProvider({ status: "serving", online: true })}
        ctx={ctx}
        fleetMaxDecodeTps={100}
      />
    );
    expect(screen.queryByTestId(AFFORDANCE)).toBeNull();
  });
});
