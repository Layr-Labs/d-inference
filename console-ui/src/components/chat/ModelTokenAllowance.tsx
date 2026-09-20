"use client";

import Link from "next/link";
import { useModelTokenPromotions } from "@/components/app-providers/ModelTokenPromotionsProvider";
import { useStore } from "@/lib/store";

export function ModelTokenAllowance() {
  const { grants, error, refresh } = useModelTokenPromotions();
  const selectedModel = useStore((s) => s.selectedModel);
  if (error) return <p role="alert" className="mx-auto mt-3 max-w-3xl text-center text-xs text-text-secondary">
    {error} <button type="button" onClick={refresh} className="font-medium text-accent-brand underline">Refresh offers</button>
  </p>;
  const grant = grants.find((item) => item.model_id === selectedModel);
  if (!grant) return null;
  const remaining = grant.total_tokens - grant.used_tokens;
  return <p role="status" className="mx-auto mt-3 max-w-3xl text-center text-xs text-text-secondary">
    {remaining > 0 ? <>
      {new Intl.NumberFormat("en-US").format(remaining)} free tokens remaining for this model. They never expire.
      {grant.reserved_tokens > 0 && <> Some tokens are reserved for active requests.</>}
      {" "}After your allowance, requests use paid credits.
    </> : <>
      You’ve used all your free tokens for this model. Requests now use paid credits.{" "}
      <Link href="/billing" className="font-medium text-accent-brand underline">Add credits</Link>
    </>}
  </p>;
}
