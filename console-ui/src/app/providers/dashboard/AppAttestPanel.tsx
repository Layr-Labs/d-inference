import { hasCurrentAppAttestAuthorization } from "../authorization";
import type { MyProvider } from "../types";
import { ProofDetails } from "@/components/verification/ProofDetails";
import { currentVerification } from "@/lib/verification";

export function AppAttestPanel({ provider }: { provider: MyProvider }) {
  if (!provider.verification) {
    const authorized = hasCurrentAppAttestAuthorization(provider);
    const expires = provider.authorization_expires_at;
    return <div className="space-y-2 text-xs text-text-secondary">
      <p className={authorized ? "font-semibold text-accent-green" : "font-semibold text-text-tertiary"}>{authorized ? "Verified via App Attest" : "App Attest authorization not current"}</p>
      <p>This coordinator reports App Attest serving authorization using its earlier status format.</p>
      <p>Authorization expires: {typeof expires === "number" && Number.isFinite(expires) && expires > 0 ? new Date(expires * 1000).toLocaleString() : "Unavailable"}.</p>
      <p>Verification time, certificate, receipt and qualified-build details are unavailable in this format. The browser displays the coordinator’s decision and has not independently validated Apple evidence.</p>
    </div>;
  }
  return <ProofDetails verification={currentVerification(provider.verification)} />;
}
