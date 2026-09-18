import { Fragment } from "react";
import { ChevronDown } from "lucide-react";
import { ProviderNodeDetail } from "../ProviderNodeDetail";
import { compactProviderId, providerRouteState, shortProviderModel, type ProviderStats } from "../provider-fleet";
import { formatCompactNumber } from "../format";

function RoutingStatus({ provider }: { provider: ProviderStats }) {
  const state = providerRouteState(provider);
  let label = "Routing excluded";
  let color = "bg-accent-amber";
  if (state === "unreported") { label = "Not reported"; color = "bg-text-tertiary"; }
  if (state === "serving") { label = "Serving"; color = "bg-accent-brand"; }
  if (state === "ready") { label = "Ready"; color = "bg-accent-green"; }
  return <span className="inline-flex items-center gap-2 whitespace-nowrap text-xs text-text-secondary sm:text-sm"><span className={`h-1.5 w-1.5 rounded-full ${color}`} aria-hidden="true" />{label}</span>;
}

export function ProviderTable({ providers, selectedId, onSelect }: { providers: ProviderStats[]; selectedId: string | null; onSelect: (id: string) => void }) {
  return (
    <table className="w-full table-fixed text-left">
      <caption className="sr-only">Provider directory. Expand a node for hardware, routing, and attestation details.</caption>
      <thead><tr className="border-b border-border-dim text-xs text-text-tertiary">
        <th scope="col" className="w-[61%] pb-3 font-normal sm:w-[32%] lg:w-[29%]">Machine</th>
        <th scope="col" className="w-[39%] pb-3 font-normal sm:w-[24%] lg:w-[19%]">Routing</th>
        <th scope="col" className="hidden w-[24%] pb-3 font-normal sm:table-cell lg:w-[22%]">Loaded model</th>
        <th scope="col" className="hidden w-[20%] pb-3 text-right font-normal sm:table-cell lg:w-[15%]">Memory</th>
        <th scope="col" className="hidden w-[15%] pb-3 text-right font-normal lg:table-cell">Tokens generated</th>
      </tr></thead>
      <tbody>{providers.map((provider) => {
        const expanded = selectedId === provider.id;
        const detailId = `provider-detail-${encodeURIComponent(provider.id)}`;
        return (
          <Fragment key={provider.id}>
            <tr className={`border-b border-border-dim transition-colors hover:bg-bg-hover ${expanded ? "bg-bg-secondary" : ""}`}>
              <td className="py-1 pr-3">
                <button type="button" onClick={() => onSelect(provider.id)} aria-expanded={expanded} aria-controls={detailId} aria-label={`${expanded ? "Hide" : "Show"} details for provider ${provider.id}`} className="flex min-h-14 w-full items-center gap-2 text-left focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent-brand sm:gap-3">
                  <ChevronDown size={15} className={`shrink-0 text-text-tertiary transition-transform motion-reduce:transition-none ${expanded ? "rotate-180" : ""}`} />
                  <span className="min-w-0"><span className="block truncate text-sm font-medium text-text-primary">{provider.chip || "Apple Silicon"}</span><span className="mt-1 block truncate text-xs text-text-tertiary">{compactProviderId(provider.id)}</span></span>
                </button>
              </td>
              <td className="py-4 pr-2"><RoutingStatus provider={provider} /></td>
              <td className="hidden truncate py-4 pr-4 text-sm text-text-secondary sm:table-cell" title={provider.current_model}>{provider.current_model ? shortProviderModel(provider.current_model) : <span className="text-text-tertiary">None loaded</span>}</td>
              <td className="hidden py-4 text-right text-sm tabular-nums text-text-secondary sm:table-cell">{provider.memory_gb.toLocaleString()} <span className="text-xs text-text-tertiary">GB</span></td>
              <td className="hidden py-4 text-right text-sm tabular-nums text-text-secondary lg:table-cell">{formatCompactNumber(provider.tokens_generated)}</td>
            </tr>
            {expanded && <tr><td colSpan={5} className="border-b border-border-dim py-4"><div id={detailId} role="region" aria-label={`Provider ${provider.id} details`}><ProviderNodeDetail provider={provider} /></div></td></tr>}
          </Fragment>
        );
      })}</tbody>
    </table>
  );
}
