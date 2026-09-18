"use client";

import { useModelTokenPromotions } from "@/components/app-providers/ModelTokenPromotionsProvider";
import { useStore } from "@/lib/store";

function claimDate(value: string) {
  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZoneName: "short" }).format(new Date(value));
}

export function ModelTokenClaims() {
  const { offers, grants, claimingModel, claim } = useModelTokenPromotions();
  const models = useStore((s) => s.models);
  const selectedModel = useStore((s) => s.selectedModel);
  const visible = offers.filter((offer) => offer.status !== "unavailable" && (offer.status !== "claimed" || (offer.model_id !== selectedModel && grants.some((grant) => grant.model_id === offer.model_id && grant.used_tokens < grant.total_tokens))));
  if (!visible.length) return null;
  return <section aria-label="Claim free model tokens" className="mx-auto mt-4 max-w-3xl space-y-3">
    {visible.map((offer) => {
      const name = models.find((model) => model.id === offer.model_id)?.display_name || offer.model_id;
      const tokens = new Intl.NumberFormat("en-US", { notation: "compact" }).format(offer.tokens);
      return <div key={offer.model_id} role={offer.status === "claimed" ? "status" : undefined} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-border-dim px-4 py-3 text-sm">
        <div className="min-w-0 flex-1">
          <p className="font-medium text-text-primary">{tokens} free tokens for {name}</p>
          {offer.status === "available" && <p className="mt-1 text-xs text-text-secondary">
            {offer.remaining_claims} of {offer.max_claims} grants left. Tokens never expire once claimed.
            {offer.claim_ends_at && <> Claim before {claimDate(offer.claim_ends_at)}.</>}
          </p>}
          {offer.status === "claimed" && <p className="mt-1 text-xs text-text-secondary">Claimed and saved to your account. Your tokens never expire.</p>}
          {offer.status === "ineligible" && <p className="mt-1 text-xs text-text-secondary">For accounts created before {claimDate(offer.signup_cutoff_at)}. Your account isn’t eligible.</p>}
          {offer.status === "sold_out" && <p className="mt-1 text-xs text-text-secondary">All {offer.max_claims} grants have been claimed.</p>}
        </div>
        {offer.status === "available" && <button type="button" disabled={claimingModel !== null} onClick={() => claim(offer.model_id)}
          className="shrink-0 rounded-lg bg-accent-brand px-4 py-2 text-xs font-semibold text-white disabled:opacity-50">
          {claimingModel === offer.model_id ? "Claiming…" : `Claim ${tokens} tokens`}
        </button>}
      </div>;
    })}
  </section>;
}
