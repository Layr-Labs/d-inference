import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { EarningsMarketResponse } from "@/lib/api/types";
import {
  DEFAULT_ELEC_COST_PER_KWH,
  HARDWARE_OPTIONS,
  baseRewardMaximumUSD,
  calculateModelEstimate,
  conservedCandidatePayout,
} from "@/app/earn/calc";

const M4_MAX_16_CORE = "M4 Max (16-core CPU)";
const MACBOOK_PRO = "MacBook Pro";
const MAC_STUDIO = "Mac Studio";

const apiMocks = vi.hoisted(() => ({
  fetchEarningsMarket: vi.fn(),
}));

vi.mock("@/components/TopBar", () => ({
  TopBar: ({ title }: { title?: string }) => (
    <div data-testid="topbar">{title}</div>
  ),
}));

vi.mock("@/hooks/useAuth", () => ({
  useAuth: () => ({
    ready: true,
    authenticated: true,
    login: vi.fn(),
  }),
}));

vi.mock("@/lib/google-analytics", () => ({
  trackEvent: vi.fn(),
}));

vi.mock("@/lib/api", () => ({
  fetchEarningsMarket: apiMocks.fetchEarningsMarket,
}));

const marketFixture: EarningsMarketResponse = {
  window_start: "2026-07-25T12:00:00Z",
  window_end: "2026-08-24T12:00:00Z",
  window_days: 30,
  models: [
    {
      id: "alpha",
      display_name: "Alpha",
      min_ram_gb: 24,
      size_bytes: 12_000_000_000,
      size_gb: 12,
      work_payout_micro_usd: 100_000_000,
      paid_tokens: 1_000_000,
      paid_jobs: 10,
      aggregate_tps: 200,
      aggregate_memory_bandwidth_gbps: 800,
      benchmark_tps: 100,
      benchmark_memory_bandwidth_gbps: 400,
      provider_supply: 2,
      estimate_available: true,
    },
    {
      id: "beta",
      display_name: "Beta",
      min_ram_gb: 36,
      size_bytes: 28_000_000_000,
      size_gb: 28,
      work_payout_micro_usd: 40_000_000,
      paid_tokens: 400_000,
      paid_jobs: 4,
      aggregate_tps: 50,
      aggregate_memory_bandwidth_gbps: 200,
      benchmark_tps: 50,
      benchmark_memory_bandwidth_gbps: 200,
      provider_supply: 1,
      estimate_available: true,
    },
    {
      id: "gamma",
      display_name: "Gamma",
      min_ram_gb: 32,
      size_bytes: 20_000_000_000,
      size_gb: 20,
      work_payout_micro_usd: 20_000_000,
      paid_tokens: 200_000,
      paid_jobs: 2,
      aggregate_tps: 40,
      aggregate_memory_bandwidth_gbps: 160,
      benchmark_tps: 0,
      benchmark_memory_bandwidth_gbps: 0,
      provider_supply: 1,
      estimate_available: false,
      unavailable_reason: "throughput_benchmark_unavailable",
    },
  ],
  audit: {
    total_settled_work_micro_usd: 160_000_000,
    modeled_work_micro_usd: 160_000_000,
    unattributed_work_micro_usd: 0,
    total_paid_tokens: 1_600_000,
    modeled_paid_tokens: 1_600_000,
    unattributed_paid_tokens: 0,
    total_paid_jobs: 16,
    modeled_paid_jobs: 16,
    unattributed_paid_jobs: 0,
  },
  base_rewards: {
    enabled: true,
    monthly_pool_micro_usd: 9_000_000_000,
    min_uptime_fraction: 0.9,
    reduction_k: 0,
    account_cap_fraction: 0,
    tiers: [
      { min_ram_gb: 64, monthly_micro_usd: 18_000_000 },
      { min_ram_gb: 48, monthly_micro_usd: 16_000_000 },
      { min_ram_gb: 32, monthly_micro_usd: 12_000_000 },
      { min_ram_gb: 24, monthly_micro_usd: 10_000_000 },
    ],
  },
};

beforeEach(() => {
  apiMocks.fetchEarningsMarket.mockReset();
  apiMocks.fetchEarningsMarket.mockResolvedValue(structuredClone(marketFixture));
});

describe("market-conserving earnings math", () => {
  it("never allocates more than the fixed settled payout pool", () => {
    const payout = conservedCandidatePayout(100, 300, 100);
    expect(payout).not.toBeNull();
    expect(payout!.candidate).toBe(25);
    expect(payout!.existing).toBe(75);
    expect(payout!.candidate + payout!.existing).toBeCloseTo(100, 12);
    expect(payout!.candidate).toBeLessThanOrEqual(100);
  });

  it("bounds the reported M4 Max case to the realized per-provider run rate", () => {
    const hardware = HARDWARE_OPTIONS.find(
      (option) => option.macType === MACBOOK_PRO && option.chip === M4_MAX_16_CORE,
    )!;
    const candidateTPS = 0.25 * hardware.bandwidthGBs;
    const model = {
      ...marketFixture.models[0],
      id: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
      display_name: "Qwen 3.6 35B A3B",
      work_payout_micro_usd: 481_450_000 * 30,
      paid_tokens: 1_000_000_000 * 30,
      paid_jobs: 10_000 * 30,
      aggregate_tps: candidateTPS * 787,
      aggregate_memory_bandwidth_gbps: hardware.bandwidthGBs * 787,
      benchmark_tps: candidateTPS,
      benchmark_memory_bandwidth_gbps: hardware.bandwidthGBs,
      provider_supply: 787,
    };

    const estimate = calculateModelEstimate(
      model,
      hardware,
      48,
      marketFixture.base_rewards,
      DEFAULT_ELEC_COST_PER_KWH,
    );

    expect(estimate).not.toBeNull();
    expect(estimate!.candidateShare).toBeCloseTo(1 / 788, 12);
    expect(estimate!.workPayoutUSD).toBeCloseTo((481.45 * 30) / 788, 8);
    expect(estimate!.monthlyNetMaximumUSD).toBeLessThan(40);
    expect(estimate!.annualNetMaximumUSD).toBeLessThan(500);
  });

  it("charges full-month idle power plus realized allocated workload", () => {
    const hardware = HARDWARE_OPTIONS.find(
      (option) => option.macType === MACBOOK_PRO && option.chip === M4_MAX_16_CORE,
    )!;
    const estimate = calculateModelEstimate(
      marketFixture.models[0],
      hardware,
      48,
      marketFixture.base_rewards,
      DEFAULT_ELEC_COST_PER_KWH,
    );
    expect(estimate).not.toBeNull();
    expect(estimate!.idleElectricityUSD).toBeCloseTo(2.16);
    expect(estimate!.workloadElectricityUSD).toBeGreaterThan(0);
    expect(estimate!.workPayoutUSD + estimate!.existingCapacityPayoutUSD).toBeCloseTo(
      estimate!.workPoolUSD,
      12,
    );
  });

  it("caps a machine's base-reward maximum at the configured fleet pool", () => {
    expect(
      baseRewardMaximumUSD(
        {
          enabled: true,
          monthly_pool_micro_usd: 5_000_000,
          min_uptime_fraction: 0.9,
          reduction_k: 0,
          account_cap_fraction: 0,
          tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
        },
        24,
      ),
    ).toBe(5);
  });

  it("keeps the reward maximum honest when offsets settle per five-minute epoch", () => {
    const policy = {
      enabled: true,
      monthly_pool_micro_usd: 100_000_000,
      min_uptime_fraction: 0.9,
      reduction_k: 0.25,
      account_cap_fraction: 0,
      tiers: [{ min_ram_gb: 24, monthly_micro_usd: 10_000_000 }],
    };
    expect(baseRewardMaximumUSD(policy, 24)).toBe(10);
    expect(
      baseRewardMaximumUSD({ ...policy, account_cap_fraction: 0.05 }, 24),
    ).toBe(5);
  });

  it("keeps form-factor-specific power profiles separate", () => {
    const m4Max = HARDWARE_OPTIONS.filter((option) => option.chip === M4_MAX_16_CORE);
    const macBook = m4Max.find((option) => option.macType === MACBOOK_PRO);
    const studio = m4Max.find((option) => option.macType === MAC_STUDIO);

    expect(macBook?.id).toBe(`${MACBOOK_PRO}:${M4_MAX_16_CORE}`);
    expect(studio?.id).toBe(`${MAC_STUDIO}:${M4_MAX_16_CORE}`);
    expect(macBook?.idleWatts).toBe(20);
    expect(studio?.idleWatts).toBe(25);
  });

  it("maps Max chip variants to their shipped bandwidth and memory combinations", () => {
    const profile = (macType: string, chip: string) =>
      HARDWARE_OPTIONS.find((option) => option.macType === macType && option.chip === chip);

    expect(profile(MACBOOK_PRO, "M3 Max (14-core CPU)")).toMatchObject({
      ramOptions: [36, 96],
      bandwidthGBs: 300,
    });
    expect(profile(MACBOOK_PRO, "M4 Max (14-core CPU)")).toMatchObject({
      ramOptions: [36],
      bandwidthGBs: 410,
    });
    expect(profile(MACBOOK_PRO, "M5 Max (32-core GPU)")).toMatchObject({
      ramOptions: [36],
      bandwidthGBs: 460,
    });
    expect(profile(MACBOOK_PRO, "M5 Max (40-core GPU)")).toMatchObject({
      ramOptions: [48, 64, 128],
      bandwidthGBs: 614,
    });
    expect(profile(MACBOOK_PRO, "M5 Pro")).toMatchObject({
      ramOptions: [24, 48, 64],
      bandwidthGBs: 307,
    });
    expect(profile(MAC_STUDIO, "M5 Max (40-core GPU)")).toBeUndefined();
    expect(profile("Mac Pro", "M3 Ultra")).toBeUndefined();
  });
});

describe("EarnPage", () => {
  it("ranks fitting models by estimated net earnings", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    expect(await screen.findByText("Best estimate")).toBeInTheDocument();
    expect(screen.getByText("Alpha")).toBeInTheDocument();
    expect(screen.getByText(/candidate share for Alpha/)).toBeInTheDocument();
    expect(screen.getByText("Estimated annual net range")).toBeInTheDocument();
    expect(screen.getByText("Supply benchmark unavailable")).toBeInTheDocument();
    expect(screen.getByText("Trailing settled payout pool")).toBeInTheDocument();
    expect(screen.getByText("Competing live capacity")).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveAttribute("aria-live", "polite");
  });

  it("does not label the highest gross-work model as best when its net is lower", async () => {
    const market = structuredClone(marketFixture);
    market.models[0].work_payout_micro_usd = 75_000_000;
    market.models[0].paid_tokens = 1_000_000_000_000;
    market.audit.total_settled_work_micro_usd = 135_000_000;
    market.audit.modeled_work_micro_usd = 135_000_000;
    market.audit.total_paid_tokens = market.models.reduce(
      (sum, model) => sum + model.paid_tokens,
      0,
    );
    market.audit.modeled_paid_tokens = market.audit.total_paid_tokens;
    apiMocks.fetchEarningsMarket.mockResolvedValueOnce(market);

    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    expect(await screen.findByText(/candidate share for Beta/)).toBeInTheDocument();
  });

  it("renders a rejected market fetch as terminally unavailable", async () => {
    apiMocks.fetchEarningsMarket.mockRejectedValueOnce(new Error("market unavailable"));
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);

    expect((await screen.findAllByText("Estimate unavailable")).length).toBeGreaterThan(0);
    expect(screen.getByText("Trailing settled-payout market data could not be loaded.")).toBeInTheDocument();
    expect(screen.queryByText("Loading trailing market data…")).not.toBeInTheDocument();
    expect(screen.getByText("Reward policy unavailable.")).toBeInTheDocument();
  });

  it("does not fabricate a base-only estimate when no model fits", async () => {
    window.localStorage.clear();
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    await screen.findAllByText(/Runs in your 48 GB/);

    fireEvent.change(screen.getByLabelText("Mac model and chip"), {
      target: { value: "MacBook Air:M1" },
    });
    fireEvent.change(screen.getByLabelText("Unified memory"), { target: { value: "16" } });

    expect(await screen.findByText("No active public model fits in 16 GB.")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Notify me when smaller models launch/ }),
    ).toBeInTheDocument();
    expect(screen.queryByText(/per month after electricity/)).not.toBeInTheDocument();
  });

  it("keeps electricity and full-month availability as stated fixed assumptions", async () => {
    const EarnPage = (await import("@/app/earn/page")).default;
    render(<EarnPage />);
    await screen.findByText("Best estimate");

    expect(screen.queryByLabelText(/Electricity cost/i)).not.toBeInTheDocument();
    expect(screen.getByText(/Full-month availability is fixed/)).toBeInTheDocument();
    expect(screen.getAllByText(/eligibility- and pool-capped/i).length).toBeGreaterThan(0);
  });
});
