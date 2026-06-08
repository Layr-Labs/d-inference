// A calm closing note on why this fleet is trustworthy — the attestation chain
// in one sentence, plus how many machines are hardware-attested. Reassures both
// the operator and a trust-minded visitor without adding noise. Counts come
// from the provider list so it always agrees with the cards above.

import { ShieldCheck } from "lucide-react";

export function TrustFooter({
  hardwareCount,
  total,
}: {
  hardwareCount: number;
  total: number;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary/60 border border-border-dim/60 p-4 flex items-start gap-3">
      <ShieldCheck size={16} className="text-accent-green shrink-0 mt-0.5" />
      <div className="text-xs text-text-secondary leading-relaxed">
        <span className="font-medium text-text-primary">
          {hardwareCount} of {total} machine{total === 1 ? "" : "s"} hardware-attested.
        </span>{" "}
        Each machine proves its identity through a Secure Enclave key, OS security posture, MDM
        enrollment, and Apple Device Attestation — the coordinator only routes paid traffic to
        hardware-verified devices, and consumers can verify the chain end-to-end.{" "}
        <a
          href="https://www.apple.com/certificateauthority/private/"
          target="_blank"
          rel="noopener noreferrer"
          className="text-accent-brand hover:underline"
        >
          Apple Root CA
        </a>
      </div>
    </div>
  );
}
