import { AlertTriangle } from "lucide-react";
import type { HardwareAdmissionAttempt } from "../types";

export function AdmissionRejectionNotice({
  attempts,
}: {
  attempts: HardwareAdmissionAttempt[];
}) {
  const settledMachines = new Set<string>();
  const rejection = attempts.find((attempt) => {
    const machine = attempt.serial_number || attempt.provider_id;
    if (settledMachines.has(machine)) return false;
    if (
      attempt.decision === "admitted" ||
      attempt.decision === "grandfathered" ||
      attempt.decision === "rejected"
    ) {
      settledMachines.add(machine);
    }
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
        </div>
      </div>
    </section>
  );
}
