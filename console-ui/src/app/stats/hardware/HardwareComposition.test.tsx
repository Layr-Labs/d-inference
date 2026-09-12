import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { HardwareComposition } from "./HardwareComposition";
import { hardwareProvider, hardwareStats } from "./hardware-test-fixtures";

describe("Hardware composition interactions", () => {
  it("preserves generation colors across ranking changes and links the memory bars to the same palette", () => {
    const m4 = hardwareProvider();
    const m3 = hardwareProvider({ chip_family: "M3" });
    const { rerender } = render(<HardwareComposition stats={hardwareStats([m4, m4, m3])} />);
    const legendColor = () => screen.getByRole("button", { name: /^M4:/ }).querySelector("span")!.style.backgroundColor;
    const initialColor = legendColor();
    expect(initialColor).toContain("77%");

    rerender(<HardwareComposition stats={hardwareStats([m3, m3, m3, m4])} />);

    expect(legendColor()).toBe(initialColor);
    const memoryBar = screen.getByRole("img", { name: /^M4:/ }).firstElementChild as HTMLElement;
    expect(memoryBar.style.backgroundColor).toBe(initialColor);
  });

  it("exposes counts and memory to keyboard users without implying routing eligibility", () => {
    render(<HardwareComposition stats={hardwareStats([hardwareProvider({ routable: false }), hardwareProvider({ chip_family: "M3", memory_gb: 128, attested: undefined })])} />);
    const generation = screen.getByRole("button", { name: "M4: 1 provider, 50% of listed providers; 64 GB of reported memory" });
    fireEvent.focus(generation);
    expect(screen.getByRole("status")).toHaveTextContent("1 M4 provider contributes 64 GB of reported memory.");
    expect(screen.getByRole("img", { name: "1 hardware identity confirmed, 0 other attestation states, 1 unreported" })).toBeInTheDocument();
    expect(screen.getByText(/Request routing depends on additional checks/)).toBeInTheDocument();
  });
});
