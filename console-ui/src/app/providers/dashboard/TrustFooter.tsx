import { ShieldCheck } from "lucide-react";
import { summarizeOwnerVerification } from "../authorization";
import type { MyProvider } from "../types";

export function TrustFooter({ providers }: { providers: MyProvider[] }) {
  const c = summarizeOwnerVerification(providers);
  const connected = providers.filter((p) => p.status !== "offline" && p.status !== "never_seen").length;
  return <div className="flex gap-3 rounded-xl border border-border-dim/60 bg-bg-secondary/60 p-4 text-xs text-text-secondary">
    <ShieldCheck size={16} className="shrink-0" />
    <p>{c.unknown === c.total && c.total > 0 ? "Authorization unavailable" : `${c.authorized} currently authorized`} of {connected} connected machines ({providers.length} owned machine records).
      {" "}{c.appAttest} App Attest · {c.legacy} legacy MDM/MDA/APNs · {c.overlap} both (counted once).
      {c.unknown > 0 && ` ${c.unknown} machine verdict(s) unavailable.`}
      {" "}Apple evidence is verified by the coordinator. Authorization expires; device reports and historical hardware proof remain separate.</p>
  </div>;
}
