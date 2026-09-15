import Link from "next/link";
import { appAttestMachineHistory } from "@/lib/queries/app-attest";

export const dynamic = "force-dynamic";
export default async function MachineEvidence({params,searchParams}: {params: Promise<{id:string}>; searchParams: Promise<{page?:string}>}) {
  const {id}=await params;
  const page=Math.max(0,Math.min(10000,Number.parseInt((await searchParams).page ?? "0",10)||0));
  const rows=await appAttestMachineHistory(id,page*100);
  return <div className="space-y-4"><Link href="/app-attest">← App Attest rollout</Link>
    <h1 className="text-lg font-semibold">Machine {id}</h1>
    <p className="text-sm text-[var(--text-dim)]">Complete submission history, 100 records per page. Downloads contain the original proof, verification context, and all receipt versions. Account and session attribution remain attached to each submission.</p>
    <div className="overflow-x-auto"><table className="w-full text-left text-sm"><thead><tr><th>Received</th><th>Action / result</th><th>Account / session</th><th>Evidence</th></tr></thead><tbody>{rows.map(r=><tr key={r.id} className="border-t border-[var(--border)]"><td className="py-3">{new Date(r.received_at).toISOString()}</td><td>{r.action}<div>{r.outcome}</div></td><td>{r.account_id || "Unlinked"}<div className="text-xs">{r.session_id}</div></td><td><a className="text-blue-400" href={`/app-attest/evidence/${r.id}`}>Download complete record</a><div className="text-xs">{r.id}</div></td></tr>)}</tbody></table></div>
    <div className="flex gap-4">{page>0&&<Link href={`?page=${page-1}`}>Previous</Link>}{rows.length===100&&<Link href={`?page=${page+1}`}>Next</Link>}</div>
  </div>;
}
