import { hasCurrentAppAttestAuthorization } from "../authorization";
import type { MyProvider } from "../types";
import { ProofDetails } from "@/components/verification/ProofDetails";
import { currentVerification, verificationPresentation } from "@/lib/verification";

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
  const verification = currentVerification(provider.verification);
  const legacyVerified = verificationPresentation(verification).legacy;
  return <div className="space-y-3">
    <ProofDetails verification={verification} />
    {legacyVerified && <p className="text-xs text-text-secondary">Legacy verification alone does not authorize MDM removal. Keep any installed Darkbloom MDM profile until <code>darkbloom unenroll</code> confirms current App Attest authorization and coordinator removal readiness.</p>}
  </div>;
}
