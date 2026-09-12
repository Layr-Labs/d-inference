import { ShieldCheck } from "lucide-react";
import { hardwareShare, type HardwareCompositionData } from "./hardware-composition";

export function HardwareIdentity({ data }: { data: HardwareCompositionData }) {
  return (
<div className="mt-7 grid gap-4 border-t border-border-dim pt-5 sm:grid-cols-[minmax(0,1fr)_minmax(240px,1fr)] sm:gap-10">
          <div>
            <h3 className="flex items-center gap-2 text-sm font-medium text-text-primary"><ShieldCheck size={16} className="text-accent-brand" />Hardware identity</h3>
            <p className="mt-1.5 max-w-md text-xs leading-relaxed text-text-secondary">Attestation confirms machine identity. Request routing depends on additional checks.</p>
          </div>
          <div>
            <p className="mb-2.5 flex justify-between gap-3 text-xs text-text-secondary"><span>{data.hardwareAttestedProviders.toLocaleString()} of {data.providers.toLocaleString()} confirmed</span><span className="font-medium tabular-nums text-text-primary">{hardwareShare(data.hardwareAttestedProviders, data.providers)}</span></p>
            <div className="flex h-2 overflow-hidden rounded-full bg-bg-secondary" role="img" aria-label={`${data.hardwareAttestedProviders} hardware ${data.hardwareAttestedProviders === 1 ? "identity" : "identities"} confirmed, ${data.otherAttestationProviders} other attestation states, ${data.attestationUnreportedProviders} unreported`}>
              <span className="h-full bg-accent-brand" style={{ width: `${data.hardwareAttestedProviders / data.providers * 100}%` }} />
              <span className="h-full bg-accent-brand/20" style={{ width: `${data.otherAttestationProviders / data.providers * 100}%` }} />
            </div>
            <p className="mt-2 text-[11px] text-text-tertiary">{data.otherAttestationProviders.toLocaleString()} other states{data.attestationUnreportedProviders > 0 ? ` · ${data.attestationUnreportedProviders.toLocaleString()} unreported` : ""}</p>
          </div>
        </div>
  );
}
