import { verificationPresentation, type Verification } from "@/lib/verification";

const date = (seconds?: number) => seconds ? new Date(seconds * 1000).toLocaleString() : "Unavailable";

/** Public proof summary: no certificate bytes, receipts, or stable identities. */
export function ProofDetails({ verification, historical = false, snapshot = false }: { verification?: Verification; historical?: boolean; snapshot?: boolean }) {
  const view = verificationPresentation(verification);
  let context = "Current serving authorization, as last checked by the coordinator. Routing also depends on model and capacity checks.";
  if (historical) context = "Verification recorded when this request was dispatched. This is not the provider’s current authorization.";
  if (snapshot) context = "Verification recorded in this network snapshot. This is not the provider’s current authorization.";
  return <div className="space-y-2 text-xs text-text-secondary">
    <p className={view.verified ? "font-semibold text-accent-green" : "font-semibold text-text-tertiary"}>{view.label}</p>
    <p>{context}</p>
    <p>Apple provides attestation evidence; Darkbloom validates it and grants permission to serve. This browser displays the coordinator’s verdict and does not independently validate Apple certificates.</p>
    <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
      <dt>Coordinator check</dt><dd>{date(verification?.observed_at)}</dd>
      <dt>App Attest</dt><dd>{verification?.app_attest.state ?? "Unavailable"}</dd>
      <dt>Assertion / grant verified</dt><dd>{date(verification?.app_attest.verified_at)}</dd>
      <dt>App Attest authorization expires</dt><dd>{date(verification?.app_attest.expires_at)}</dd>
      <dt>Legacy authorization</dt><dd>{verification?.legacy.state ?? "Unavailable"}</dd>
      <dt>Legacy challenge verified</dt><dd>{date(verification?.legacy.verified_at)}</dd>
      <dt>Legacy authorization expires</dt><dd>{date(verification?.legacy.expires_at)}</dd>
      <dt>Certificate / key enrollment details</dt><dd>Not published</dd>
      <dt>Apple receipt details and risk metric</dt><dd>Not published</dd>
      <dt>Qualified signed build details</dt><dd>Not published</dd>
    </dl>
    {view.appAttest && <p>The App Attest grant requires Apple certificate-chain and key-enrollment validation, a fresh assertion bound to this connection, receipt policy, and a qualified signed build. These checks do not certify reported RAM, chip, or macOS properties, or prove the correctness of an inference.</p>}
    {view.legacy && <p>The legacy path passed the coordinator’s configured hardware, application and challenge policy. Individual MDA or APNs evidence is not inferred from the legacy trust field.</p>}
    <p>Raw certificates, Apple receipts, account and credential identifiers remain private. Device properties shown elsewhere are reported metadata unless explicitly identified as Apple-certified.</p>
  </div>;
}
