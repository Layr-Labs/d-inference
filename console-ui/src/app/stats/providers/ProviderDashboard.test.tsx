import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { ProviderDashboard } from "../ProviderDashboard";
import type { ProviderStats } from "../provider-fleet";
import { DEFAULT_DIRECTORY_FILTERS, filterProviderDirectory, providerDirectoryPage } from "./provider-directory";

function provider(index: number, extra: Partial<ProviderStats> = {}): ProviderStats {
  return {
    id: `node-${String(index).padStart(3, "0")}`, chip: "Apple M4 Max", chip_family: "M4", chip_tier: "Max", machine_model: "Mac Studio", memory_gb: 64, gpu_cores: 40,
    cpu_cores: { total: 16, performance: 12, efficiency: 4 }, memory_bandwidth_gbs: 546, status: "online", trust_level: "hardware", decode_tps: 30,
    requests_served: 50, tokens_generated: 1500, routable: true, models: ["qwen3"], ...extra,
  };
}

const FIRST_PROVIDER_BUTTON = "Show details for provider node-001";
const fleet = Array.from({ length: 52 }, (_, index) => provider(index + 1));

describe("Provider directory", () => {
  it("renders one page of nodes and a single inspector on request", () => {
    render(<ProviderDashboard providers={fleet} />);
    expect(screen.getAllByRole("button", { name: /Show details for provider/ })).toHaveLength(25);
    expect(screen.queryByRole("region", { name: /Provider .* details/ })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: FIRST_PROVIDER_BUTTON }));
    expect(screen.getByRole("region", { name: "Provider node-001 details" })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Show details for provider node-002" }));
    expect(screen.getAllByRole("region", { name: /Provider .* details/ })).toHaveLength(1);
    expect(screen.queryByRole("region", { name: "Provider node-001 details" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Next provider page" }));
    expect(screen.queryByRole("button", { name: FIRST_PROVIDER_BUTTON })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Show details for provider node-026" })).toBeInTheDocument();
    expect(screen.queryByRole("region", { name: /Provider .* details/ })).not.toBeInTheDocument();
  });

  it("resets pagination for a new search and exposes filter controls on demand", () => {
    render(<ProviderDashboard providers={fleet} />);
    fireEvent.click(screen.getByRole("button", { name: "Next provider page" }));
    fireEvent.change(screen.getByRole("searchbox", { name: "Search provider fleet" }), { target: { value: "node-003" } });
    expect(screen.getByRole("button", { name: "Show details for provider node-003" })).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("1–1 of 1 nodes");
    expect(screen.queryByRole("combobox", { name: "Filter by model" })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Filters" }));
    expect(screen.getByRole("combobox", { name: "Filter by model" })).toBeInTheDocument();
  });

  it("does not present missing routing verdicts as routing eligibility", () => {
    render(<ProviderDashboard providers={[provider(1, { routable: undefined, runtime_verified: true, last_challenge_verified: new Date().toISOString() })]} />);
    expect(screen.getByText("Hardware verified")).toBeInTheDocument();
    expect(screen.getByText("Not reported")).toBeInTheDocument();
    expect(screen.queryByText("Routing eligible")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: FIRST_PROVIDER_BUTTON }));
    expect(screen.getByText("Routing not reported")).toBeInTheDocument();
  });

  it("includes the active model when an advertised model list is omitted", () => {
    const result = filterProviderDirectory([provider(1, { models: [], current_model: "gemma-4" }), provider(2)], { ...DEFAULT_DIRECTORY_FILTERS, model: "gemma-4" });
    expect(result.map((node) => node.id)).toEqual(["node-001"]);
  });

  it("clamps the current page when the fleet shrinks", () => {
    const page = providerDirectoryPage(fleet.slice(0, 3), 3);
    expect(page.page).toBe(1);
    expect(page.providers).toHaveLength(3);
  });
});
