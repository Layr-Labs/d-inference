// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { SummaryStats } from "./SummaryStats";

describe("SummaryStats", () => {
  it("renders lifetime totals with separators", () => {
    render(<SummaryStats totalMicro={1_284_360_000} jobs={18_742} />);
    expect(screen.getByText("$1,284.36")).toBeInTheDocument();
    expect(screen.getByText("18,742")).toBeInTheDocument();
    expect(screen.getByText("$0.0685")).toBeInTheDocument();
  });

  it("shows a consistent $0.00 average with zero jobs (EMPTY)", () => {
    render(<SummaryStats totalMicro={0} jobs={0} />);
    expect(screen.getByText("0")).toBeInTheDocument();
    // Total earned and avg-per-job both read $0.00 — no stray "0.000000".
    expect(screen.getAllByText("$0.00")).toHaveLength(2);
  });
});
