// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AdmissionRejectionNotice } from "./AdmissionRejectionNotice";

describe("AdmissionRejectionNotice", () => {
  it("renders exact coordinator deficits for a rejected machine", () => {
    render(
      <AdmissionRejectionNotice
        attempts={[
          {
            id: 1,
            provider_id: "provider-1",
            policy_version: 4,
            mode: "enforce",
            decision: "rejected",
            reason_code: "hardware_below_minimum",
            hardware: { memory_gb: 16 },
            failed_checks: [
              {
                code: "memory_below_minimum",
                metric: "memory_gb",
                observed: 16,
                required: 32,
                unit: "GiB",
              },
            ],
            created_at: "2026-08-25T00:00:00Z",
          },
        ]}
      />
    );
    expect(
      screen.getByText("New provider hardware was not admitted")
    ).toBeInTheDocument();
    expect(
      screen.getByText(/16 GiB reported, 32 GiB required/)
    ).toBeInTheDocument();
    expect(screen.getByText(/policy v4/)).toBeInTheDocument();
  });

  it("stays hidden when there is no hardware rejection", () => {
    const { container } = render(<AdmissionRejectionNotice attempts={[]} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("hides a historical rejection after the same machine is admitted", () => {
    const base = {
      provider_id: "provider-1",
      serial_number: "SERIAL-1",
      policy_version: 4,
      mode: "enforce",
      hardware: { memory_gb: 32 },
    };
    const { container } = render(
      <AdmissionRejectionNotice
        attempts={[
          {
            ...base,
            id: 2,
            decision: "admitted",
            created_at: "2026-08-25T01:00:00Z",
          },
          {
            ...base,
            id: 1,
            decision: "rejected",
            reason_code: "hardware_below_minimum",
            created_at: "2026-08-25T00:00:00Z",
          },
        ]}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });
});
