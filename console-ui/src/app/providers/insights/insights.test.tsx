import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, expect, it, vi } from "vitest";
import { LiveModels } from "./LiveModels";
import { TokenMilestones } from "./TokenMilestones";
import { EarningsAnalyticsView } from "./EarningsAnalytics";
import { makeInsights } from "./testFixtures";
import { makeProvider } from "../dashboard/testFixtures";
vi.mock("@/hooks/useAuth", () => ({ useAuth: () => ({ ready: false, authenticated: false }) }));
afterEach(() => { cleanup(); vi.useRealTimers(); });

it("stops representing requests as live when polling fails and supports paused motion", () => {
  const provider = makeProvider({ online: true, capacity_accepted_at: new Date().toISOString(), backend_capacity: { slots: [{ model: "Qwen3", state: "running", num_running: 6, num_waiting: 0, active_tokens: 60, max_tokens_potential: 100 }], gpu_memory_active_gb: 1, gpu_memory_cache_gb: 0, gpu_memory_peak_gb: 1, total_memory_gb: 64 } });
  const props = { providers: [provider], heartbeatSeconds: 90, lastUpdatedAt: Date.now() };
  const { rerender, container } = render(<LiveModels {...props} pollFailed={false} />);
  expect(screen.getByText("6 running")).toBeInTheDocument();
  expect(container.querySelectorAll('[data-active="true"]')).toHaveLength(6);
  fireEvent.click(screen.getByRole("button", { name: "Pause activity animation" }));
  expect(container.querySelector('[data-animate="false"]')).toBeInTheDocument();
  rerender(<LiveModels {...props} pollFailed />);
  expect(screen.queryByText("6 running")).not.toBeInTheDocument();
  expect(container.querySelectorAll('[data-active="true"]')).toHaveLength(0);
  expect(screen.getByText("Activity delayed")).toBeInTheDocument();
});

it("labels milestone provenance and renders bounded progress without fabricated achievements", () => {
  render(<TokenMilestones tokens={100_000} />);
  expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "0");
  expect(screen.getByText("Reached")).toBeInTheDocument();
  expect(screen.getByText(/including removed Macs/)).toBeInTheDocument();
});

it("celebrates only a newly crossed milestone and clears the message", () => {
  vi.useFakeTimers();
  const { rerender } = render(<TokenMilestones tokens={999_999} />);
  expect(screen.queryByText(/Milestone reached!/)).not.toBeInTheDocument();
  rerender(<TokenMilestones tokens={1_000_000} />);
  expect(screen.getByText("1M output tokens. Milestone reached!")).toBeInTheDocument();
  rerender(<TokenMilestones tokens={999_999} />);
  act(() => vi.advanceTimersByTime(10_000));
  expect(screen.queryByText(/Milestone reached!/)).not.toBeInTheDocument();
  rerender(<TokenMilestones tokens={1_000_000} />);
  expect(screen.queryByText(/Milestone reached!/)).not.toBeInTheDocument();
});

it("switches chart metric and breakdown while keeping rewards out of per-request earnings", () => {
  const onWindowChange = vi.fn();
  render(<EarningsAnalyticsView data={makeInsights()} window="7d" onWindowChange={onWindowChange} />);
  expect(screen.getByText("$0.05 average inference earnings")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "Output tokens" }));
  expect(screen.getByRole("group", { name: "Daily tokens in UTC" })).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "By Mac" }));
  expect(screen.getByText("Mac mac-one")).toBeInTheDocument();
  fireEvent.click(screen.getByRole("button", { name: "30 days" }));
  expect(onWindowChange).toHaveBeenCalledWith("30d");
  expect(screen.getByText("Today so far · UTC")).toBeInTheDocument();
});
