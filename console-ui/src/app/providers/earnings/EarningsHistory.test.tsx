// @vitest-environment jsdom
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { EarningsHistory, PAGE_SIZE } from "./EarningsHistory";
import { FIXTURE_NOW, makeEarning, makeScenario } from "./testFixtures";
import type { EarningsResponse } from "./types";

// Time-window filtering compares row timestamps against Date.now().
beforeEach(() => vi.useFakeTimers({ now: FIXTURE_NOW, toFake: ["Date"] }));
afterEach(() => vi.useRealTimers());

const QWEN_SHORT = "Qwen3-30B-A3B";

function renderResponse(r: EarningsResponse) {
  render(
    <EarningsHistory
      earnings={r.earnings}
      totalJobs={r.count}
      recentCount={r.recent_count}
    />,
  );
}

/** Rows for one model, enough to spill onto a second page. */
function manyRowsResponse(rowCount: number): EarningsResponse {
  const rows = Array.from({ length: rowCount }, (_, i) =>
    makeEarning({
      id: i + 1,
      job_id: `job-${i + 1}`,
      created_at: new Date(FIXTURE_NOW - i * 60_000).toISOString(),
    }),
  );
  return {
    ...makeScenario("EMPTY"),
    earnings: rows,
    count: rowCount,
    recent_count: rowCount,
  };
}

describe("EarningsHistory summary view", () => {
  it("shows the empty state with no rows (EMPTY)", () => {
    renderResponse(makeScenario("EMPTY"));
    expect(screen.getByText("No earnings activity yet")).toBeInTheDocument();
    expect(screen.queryByRole("table")).toBeNull();
  });

  it("shows one summary row per model instead of a log (TYPICAL)", () => {
    renderResponse(makeScenario("TYPICAL"));
    // 3 distinct models -> 3 summary buttons, no table.
    expect(screen.getAllByRole("listitem")).toHaveLength(3);
    expect(screen.queryByRole("table")).toBeNull();
    expect(screen.getByText(QWEN_SHORT)).toBeInTheDocument();
  });

  it("shows the latest-N-of-M note when the server truncated (TRUNCATED)", () => {
    renderResponse(makeScenario("TRUNCATED"));
    expect(
      screen.getByText("Showing the latest 100 of 4,210 payouts."),
    ).toBeInTheDocument();
  });

  it("keeps full model ids when two orgs share a short name", () => {
    const s = makeScenario("TYPICAL");
    const rows = s.earnings.slice(0, 2).map((e, i) => ({
      ...e,
      id: 9000 + i,
      model: i === 0 ? "Qwen/Qwen3-30B-A3B" : "other-org/Qwen3-30B-A3B",
    }));
    renderResponse({ ...s, earnings: rows, count: 2, recent_count: 2 });
    expect(screen.getByText("Qwen/Qwen3-30B-A3B")).toBeInTheDocument();
    expect(screen.getByText("other-org/Qwen3-30B-A3B")).toBeInTheDocument();
  });
});

describe("EarningsHistory drill-down log", () => {
  it("opens a model's log on click and returns via All models", () => {
    renderResponse(makeScenario("TYPICAL"));
    fireEvent.click(screen.getByText("gemma-3-27b-it"));
    // Log view: a table whose rows are all the clicked model.
    const table = screen.getByRole("table");
    expect(table).toBeInTheDocument();
    expect(screen.getAllByText("gemma-3-27b-it").length).toBeGreaterThan(1);
    expect(screen.queryByText("Qwen3-VL-8B")).toBeNull();

    fireEvent.click(screen.getByRole("button", { name: /all models/i }));
    expect(screen.queryByRole("table")).toBeNull();
    expect(screen.getAllByRole("listitem")).toHaveLength(3);
  });

  it("paginates the log at 25 rows per page", () => {
    renderResponse(manyRowsResponse(60));
    fireEvent.click(screen.getByText(QWEN_SHORT));

    // Page 1: 25 rows + header row.
    expect(screen.getAllByRole("row")).toHaveLength(PAGE_SIZE + 1);
    expect(screen.getByText(/Page 1 of 3/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /previous/i })).toBeDisabled();

    fireEvent.click(screen.getByRole("button", { name: /next/i }));
    expect(screen.getByText(/Page 2 of 3/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /previous/i })).not.toBeDisabled();

    fireEvent.click(screen.getByRole("button", { name: /next/i }));
    // Last page: 60 - 50 = 10 rows + header.
    expect(screen.getAllByRole("row")).toHaveLength(10 + 1);
    expect(screen.getByRole("button", { name: /next/i })).toBeDisabled();
  });

  it("hides the pager when a page is enough", () => {
    renderResponse(manyRowsResponse(10));
    fireEvent.click(screen.getByText(QWEN_SHORT));
    expect(screen.getAllByRole("row")).toHaveLength(10 + 1);
    expect(screen.queryByText(/Page 1/)).toBeNull();
  });

  it("resets to page 1 when the time range changes", () => {
    renderResponse(manyRowsResponse(60));
    fireEvent.click(screen.getByText(QWEN_SHORT));
    fireEvent.click(screen.getByRole("button", { name: /next/i }));
    expect(screen.getByText(/Page 2 of 3/)).toBeInTheDocument();
    fireEvent.change(screen.getByLabelText("Filter by time range"), {
      target: { value: "7" },
    });
    expect(screen.getByText(/Page 1 of 3/)).toBeInTheDocument();
  });

  it("filters both views by the time range", () => {
    renderResponse(makeScenario("TYPICAL"));
    fireEvent.change(screen.getByLabelText("Filter by time range"), {
      target: { value: "7" },
    });
    // Summaries survive but cover fewer jobs than all-time.
    expect(screen.getAllByRole("listitem").length).toBeGreaterThan(0);
  });
});
