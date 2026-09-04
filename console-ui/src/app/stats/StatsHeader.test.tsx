import { render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { StatsHeader } from "./StatsHeader";

const fetchedAt = "2026-09-04T12:01:00Z";
const props = { fetchedAt, hasSnapshot: true, refreshing: false, error: null, onRefresh: vi.fn() };
beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(new Date(fetchedAt)); });
afterEach(() => vi.useRealTimers());

describe("Snapshot freshness", () => {
  it("marks retained older source snapshots as stale even after a successful fetch", () => {
    render(<StatsHeader {...props} snapshotAt="2026-09-04T12:00:00Z" />);
    expect(screen.getByText("Snapshot 1m ago (stale)")).toBeInTheDocument();
  });
  it("keeps recent source snapshots distinct from fetch timestamps", () => {
    render(<StatsHeader {...props} snapshotAt="2026-09-04T12:00:58Z" />);
    expect(screen.getByText("Snapshot 2s ago")).toBeInTheDocument();
    expect(screen.queryByText(/stale/)).not.toBeInTheDocument();
  });
  it("does not infer source age from a legacy response's fetch time", () => {
    render(<StatsHeader {...props} fetchedAt="2026-09-04T12:00:00Z" snapshotAt={null} />);
    expect(screen.getByText("Fetched 1m ago")).toBeInTheDocument();
    expect(screen.queryByText(/stale/)).not.toBeInTheDocument();
  });
});
