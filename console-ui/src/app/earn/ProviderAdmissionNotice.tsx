import Link from "next/link";
import { AlertTriangle, ShieldCheck } from "lucide-react";
import type { ProviderRequirementsState } from "../providers/useProviderRequirements";
import type { EarningsCalculator } from "./useEarningsCalculator";

function waitlistHref(calc: EarningsCalculator): string {
  const params = new URLSearchParams({
    chip: calc.selectedChip,
    memory_gb: String(calc.effectiveRAM),
  });
  return `/provider-waitlist?${params.toString()}`;
}

export function ProviderAdmissionNotice({
  calc,
  requirementsState,
}: {
  calc: EarningsCalculator;
  requirementsState: ProviderRequirementsState;
}) {
  if (requirementsState.status === "loading") {
    return (
      <p
        aria-live="polite"
        className="mb-6 rounded-xl border border-border-default bg-bg-secondary px-4 py-3 text-sm text-text-secondary"
      >
        Checking the coordinator&apos;s current new-machine admission policy…
      </p>
    );
  }

  const policy = requirementsState.requirements?.policy;
  if (requirementsState.status === "error" || !policy) {
    return (
      <section
        role="alert"
        className="mb-6 rounded-xl border border-accent-amber/25 bg-accent-amber/10 px-4 py-3 text-sm text-text-secondary"
      >
        <p>
          Current new-machine requirements are temporarily unavailable. Earnings
          below are model-fit projections, not provider admission approval.
        </p>
        <Link
          href={waitlistHref(calc)}
          className="mt-2 inline-flex font-semibold text-accent-brand hover:text-accent-brand-hover"
        >
          Open hardware interest registration
        </Link>
      </section>
    );
  }

  if (policy.mode === "disabled") {
    return null;
  }

  const belowMemoryFloor =
    policy.mode === "enforce" &&
    policy.min_memory_gb > 0 &&
    calc.effectiveRAM < policy.min_memory_gb;
  const Icon = belowMemoryFloor ? AlertTriangle : ShieldCheck;

  return (
    <section
      role={belowMemoryFloor ? "alert" : undefined}
      className={`mb-6 rounded-xl border px-4 py-3 text-sm ${
        belowMemoryFloor
          ? "border-accent-red/25 bg-accent-red/10"
          : "border-accent-amber/25 bg-accent-amber/10"
      }`}
    >
      <div className="flex items-start gap-2.5">
        <Icon
          size={17}
          aria-hidden="true"
          className={belowMemoryFloor ? "mt-0.5 text-accent-red" : "mt-0.5 text-accent-amber"}
        />
        <div>
          <p className="font-semibold text-text-primary">
            {belowMemoryFloor
              ? "This Mac is below the current new-provider memory floor"
              : `New-machine policy v${policy.version} is ${policy.mode}`}
          </p>
          <p className="mt-1 leading-relaxed text-text-secondary">
            {belowMemoryFloor
              ? `${calc.effectiveRAM} GiB is selected; policy v${policy.version} requires at least ${policy.min_memory_gb} GiB. This configuration will not be admitted as a new provider.`
              : "This projection measures model fit and possible earnings, not admission approval. The coordinator verifies the exact chip, GPU-core count, signed hardware, and current policy when a provider connects."}
          </p>
          {(belowMemoryFloor || policy.mode === "enforce") && (
            <Link
              href={waitlistHref(calc)}
              className="mt-2 inline-flex font-semibold text-accent-brand hover:text-accent-brand-hover"
            >
              {belowMemoryFloor
                ? "Register this Mac's hardware interest"
                : "Open hardware interest registration"}
            </Link>
          )}
        </div>
      </div>
    </section>
  );
}
