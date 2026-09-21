// Keep App Attest authorization and legacy hardware proof counts distinct.
// Counts come from the same current provider list as the cards above.

import { ShieldCheck } from "lucide-react";

export function TrustFooter({
  hardwareCount,
  appAttestCount = 0,
  total,
}: {
  hardwareCount: number;
  appAttestCount?: number;
  total: number;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary/60 border border-border-dim/60 p-4 flex items-start gap-3">
      <ShieldCheck size={16} className="text-accent-green shrink-0 mt-0.5" />
      <div className="text-xs text-text-secondary leading-relaxed">
        <span className="font-medium text-text-primary">
          {appAttestCount} with current App Attest authorization. {hardwareCount} of {total} machine{total === 1 ? "" : "s"} with legacy hardware verification.
        </span>{" "}
        Serving requires qualified App Attest on macOS 27 or later, or complete legacy MDM,
        Apple Device Attestation and APNs verification. The coordinator checks authorization
        before dispatch and publishes only privacy-redacted trust status.{" "}
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
