// @vitest-environment jsdom
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { AdmissionRejectionNotice } from "./AdmissionRejectionNotice";

const PROVIDER_ID = "provider-1";
const REJECTION_TIME = "2026-08-25T00:00:00Z";

describe("AdmissionRejectionNotice", () => {
  it("renders exact coordinator deficits for a rejected machine", () => {
    render(
      <AdmissionRejectionNotice
        attempts={[
          {
            id: 1,
            provider_id: PROVIDER_ID,
            policy_version: 4,
            mode: "enforce",
            decision: "rejected",
            reason_code: "hardware_below_minimum",
            hardware: {
              chip_family: "M4",
              chip_tier: "max",
              memory_gb: 16,
              gpu_cores: 40,
            },
            failed_checks: [
              {
                code: "memory_below_minimum",
                metric: "memory_gb",
                observed: 16,
                required: 32,
                unit: "GiB",
              },
            ],
            created_at: REJECTION_TIME,
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
    expect(
      screen.getByRole("link", { name: "Register hardware interest" })
    ).toHaveAttribute(
      "href",
      "/provider-waitlist?chip=M4+Max&memory_gb=16&gpu_cores=40"
    );
  });

  it("stays hidden when there is no hardware rejection", () => {
    const { container } = render(<AdmissionRejectionNotice attempts={[]} />);
    expect(container).toBeEmptyDOMElement();
  });

  it("hides a historical rejection after the same machine is admitted", () => {
    const base = {
      provider_id: PROVIDER_ID,
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
            created_at: REJECTION_TIME,
          },
        ]}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });

  it("hides a historical rejection while the same machine is pending", () => {
    const base = {
      provider_id: PROVIDER_ID,
      serial_number: "SERIAL-1",
      policy_version: 5,
      mode: "enforce",
      hardware: { memory_gb: 32 },
    };
    const { container } = render(
      <AdmissionRejectionNotice
        attempts={[
          {
            ...base,
            id: 2,
            decision: "pending_identity",
            created_at: "2026-08-25T01:00:00Z",
          },
          {
            ...base,
            id: 1,
            policy_version: 4,
            decision: "rejected",
            reason_code: "hardware_below_minimum",
            created_at: REJECTION_TIME,
          },
        ]}
      />
    );
    expect(container).toBeEmptyDOMElement();
  });
});
