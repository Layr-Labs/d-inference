import { redirect } from "next/navigation";
import { normalizeReferral } from "@/components/referrals/attribution";

export default async function ConsoleHomePage({ searchParams }: { searchParams: Promise<{ ref?: string | string[] }> }) {
  const { ref } = await searchParams;
  const code = normalizeReferral(typeof ref === "string" ? ref : null);
  // Legacy shared links landed at /. Preserve their attribution before this
  // server redirect runs, since the client provider has not hydrated yet.
  if (code) redirect(`/referrals?ref=${encodeURIComponent(code)}`);
  redirect("/providers");
}
