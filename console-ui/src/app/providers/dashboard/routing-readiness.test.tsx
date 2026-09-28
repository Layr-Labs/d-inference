import { describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import { baseProvider, ctx } from "../../../../__tests__/provider-dashboard-fixtures";
import { buildAttentionGroups, deriveFleetVerdict } from "./aggregate";
import { routingFor, selectTopWarning } from "./routing";
import { computeWarnings } from "../warnings";
import { CardRoutingVerdict } from "./CardRoutingVerdict";
import { FleetHealthStrip } from "./FleetHealthStrip";
import { AttentionFeed } from "./AttentionFeed";

function renderReadiness(overrides: Parameters<typeof baseProvider>[0] = {}) {
  const provider = baseProvider({
    pending_requests: 0, lifetime_requests_served: 0, lifetime_tokens_generated: 0,
    reputation: { total_jobs: 0, successful_jobs: 0, failed_jobs: 0,
      total_uptime_seconds: 3600, avg_response_time_ms: 0, challenges_passed: 5, challenges_failed: 0 },
    ...overrides,
  });
  const warnings = computeWarnings(provider, ctx);
  render(<>
    <CardRoutingVerdict provider={provider} state={routingFor(provider, ctx)} topWarning={selectTopWarning(warnings)} />
    <FleetHealthStrip verdict={deriveFleetVerdict([provider], ctx)} summary={null} />
    <AttentionFeed groups={buildAttentionGroups([provider], ctx)} />
  </>);
}

describe("routing readiness without request evidence", () => {
  it("does not promise traffic or earnings for a healthy idle provider and links to diagnosis", () => {
    renderReadiness();
    expect(screen.getByText("READY FOR ROUTING")).toBeVisible();
    expect(screen.getByText("Fleet ready for routing")).toBeVisible();
    expect(screen.getByText("Routable")).toBeVisible();
    expect(screen.queryByText(/receiving traffic|everything.s earning|earning now|routable and earning|no action needed/i)).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Healthy but no requests?" })).toHaveAttribute("href",
      "https://github.com/Layr-Labs/d-inference/blob/master/docs/provider/troubleshooting.md#healthy-but-no-requests");
  });

  it("does not claim reduced earnings for a thermally degraded idle provider", () => {
    renderReadiness({ system_metrics: { memory_pressure: 0.2, cpu_usage: 0.1, thermal_state: "serious" } });
    expect(screen.getByText("ROUTING DEGRADED")).toBeVisible();
    expect(screen.queryByText(/still earning|EARNING \(reduced priority\)/i)).not.toBeInTheDocument();
  });

  it("retains the blocking diagnosis and does not offer an all-clear", () => {
    renderReadiness({ runtime_verified: false });
    expect(screen.getByText("ROUTING BLOCKED")).toBeVisible();
    expect(screen.queryByText("READY FOR ROUTING")).not.toBeInTheDocument();
    expect(screen.queryByRole("link", { name: "Healthy but no requests?" })).not.toBeInTheDocument();
  });

  it("does not describe an empty fleet as ready or earning", () => {
    const verdict = deriveFleetVerdict([], ctx);
    expect(verdict.headline).toBe("No machines linked");
    expect(verdict.counts.total).toBe(0);
  });
});
