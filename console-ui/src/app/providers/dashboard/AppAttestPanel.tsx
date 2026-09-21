import type { MyProvider } from "../types";
import { hasCurrentAppAttestAuthorization } from "../authorization";

export function AppAttestPanel({ provider }: { provider: MyProvider }) {
  const authorized = hasCurrentAppAttestAuthorization(provider);
  return (
    <div className="space-y-2 text-xs text-text-secondary">
      <p className={`font-semibold ${authorized ? "text-accent-green" : "text-accent-amber"}`}>
        {authorized ? "App Attest serving authorization verified" : "Awaiting fresh App Attest authorization"}
      </p>
      <p>{authorized
        ? "The coordinator verified this signed provider and its connection. Darkbloom MDM enrollment is not required for this authorization path."
        : "The previous authorization has expired or is no longer current. Run darkbloom status or darkbloom doctor to check verification."}</p>
      <p>Keep existing management profiles installed. To migrate an existing Darkbloom profile, run darkbloom unenroll and choose App Attest; the CLI checks current removal approval. Keep employer management in place.</p>
    </div>
  );
}
