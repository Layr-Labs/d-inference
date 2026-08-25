import { AlertTriangle, ArrowRight } from "lucide-react";
import Link from "next/link";
import type { HardwareAdmissionAttempt } from "../types";

function waitlistHref(attempt: HardwareAdmissionAttempt): string {
  const hardware = attempt.hardware;
  const tier = hardware.chip_tier?.trim();
  let chip = hardware.chip_family?.trim() ?? "";
  if (chip && tier && tier.toLowerCase() !== "base") {
    chip += ` ${tier.charAt(0).toUpperCase()}${tier.slice(1).toLowerCase()}`;
  }
  if (!chip) {
    chip =
      hardware.chip_name?.replace(/^Apple\s+/i, "").trim() ||
      hardware.machine_model?.trim() ||
      "";
  }

  const params = new URLSearchParams();
  if (chip) params.set("chip", chip);
  if (hardware.memory_gb) {
    params.set("memory_gb", String(hardware.memory_gb));
  }
  if (hardware.gpu_cores) {
    params.set("gpu_cores", String(hardware.gpu_cores));
  }
  const query = params.toString();
  return query ? `/provider-waitlist?${query}` : "/provider-waitlist";
}

export function AdmissionRejectionNotice({
  attempts,
}: {
  attempts: HardwareAdmissionAttempt[];
}) {
  const latestMachines = new Set<string>();
  const rejection = attempts.find((attempt) => {
    const machine = attempt.serial_number || attempt.provider_id;
    if (latestMachines.has(machine)) return false;
    latestMachines.add(machine);
    return (
      attempt.decision === "rejected" &&
      attempt.reason_code === "hardware_below_minimum"
    );
  });
  if (!rejection) return null;

  const deficits = (rejection.failed_checks ?? []).map((failure) => {
    if (failure.code === "hardware_not_catalogued") {
      return "Hardware SKU is not yet catalogued";
    }
    if (failure.code === "hardware_claim_mismatch") {
      return "Reported hardware did not match the attested machine";
    }
    return `${failure.metric}: ${failure.observed} ${failure.unit} reported, ${failure.required} ${failure.unit} required`;
  });

  return (
    <section
      role="alert"
      className="rounded-xl border border-accent-red/25 bg-accent-red-dim p-4"
    >
      <div className="flex items-start gap-3">
        <AlertTriangle className="mt-0.5 shrink-0 text-accent-red" size={18} />
        <div>
          <h2 className="text-sm font-semibold text-text-primary">
            New provider hardware was not admitted
          </h2>
          <p className="mt-1 text-sm text-text-secondary">
            This machine did not meet hardware policy v
            {rejection.policy_version}. Existing admitted machines remain
            grandfathered.
          </p>
          {deficits.length > 0 && (
            <ul className="mt-2 space-y-1 text-xs text-text-secondary">
              {deficits.map((deficit) => (
                <li key={deficit}>• {deficit}</li>
              ))}
            </ul>
          )}
          <Link
            href={waitlistHref(rejection)}
            className="mt-3 inline-flex items-center gap-1.5 text-sm font-semibold text-accent-brand transition-colors hover:text-accent-brand-hover focus-ring"
          >
            Register hardware interest
            <ArrowRight size={14} aria-hidden="true" />
          </Link>
        </div>
      </div>
    </section>
  );
}
