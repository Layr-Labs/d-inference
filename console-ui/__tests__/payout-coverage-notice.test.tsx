import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { PayoutCoverageNotice } from "@/components/payouts/PayoutCoverageNotice";

describe("PayoutCoverageNotice", () => {
  it("renders the coverage caveat", () => {
    render(<PayoutCoverageNotice />);
    expect(
      screen.getByText(/payouts aren't available in every country yet/),
    ).toBeTruthy();
    expect(
      screen.getByText(/check whether your country's withdrawal path/),
    ).toBeTruthy();
  });
});
