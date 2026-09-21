import { ShieldCheck } from "lucide-react";
import { summarizeVerification } from "@/lib/verification";
import type { MyProvider } from "../types";

export function TrustFooter({ providers }: { providers: MyProvider[] }) {
  const c = summarizeVerification(providers);
  const online = providers.filter((p) => p.online).length;
  return <div className="flex gap-3 rounded-xl border border-border-dim/60 bg-bg-secondary/60 p-4 text-xs text-text-secondary">
    <ShieldCheck size={16} className="shrink-0" />
    <p>{c.authorized} currently authorized of {online} connected machines ({providers.length} owned machine records).
      {" "}{c.appAttest} App Attest · {c.legacy} legacy MDM/MDA/APNs · {c.overlap} both (counted once).
      {" "}Apple evidence is verified by the coordinator. Authorization expires; device reports and historical hardware proof remain separate.</p>
  </div>;
}
