"use client";

import { ShieldCheck } from "lucide-react";
import { providerRouteReason, providerRouteState, relativeChallengeLabel, shortProviderModel, type ProviderStats } from "./provider-fleet";
import { formatCompactNumber } from "./format";

function DetailMetric({ label, value }: { label: string; value: string }) {
  return <div><dt className="text-xs text-text-tertiary">{label}</dt><dd className="mt-1.5 text-base font-medium tabular-nums text-text-primary">{value}</dd></div>;
}

export function ProviderNodeDetail({ provider }: { provider: ProviderStats | null }) {
  if (!provider) return <p className="p-6 text-sm text-text-tertiary">Select a node to inspect its hardware and routing status.</p>;
  const state = providerRouteState(provider);
  const models = provider.models ?? [];
  let stateLabel = "Routing excluded";
  if (state === "unreported") stateLabel = "Routing not reported";
  if (state === "serving") stateLabel = "Serving requests";
  if (state === "ready") stateLabel = "Routing eligible";
  let certificate = "Not published";
  if (provider.mda_verified === true) certificate = "Verified";
  if (provider.mda_verified === false) certificate = "Not verified";

  return (
    <article className="rounded-2xl bg-bg-secondary p-5 sm:p-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div><h3 className="text-base font-semibold text-text-primary">{provider.machine_model || provider.chip || "Apple Silicon"}</h3><p className="mt-1 break-all text-xs text-text-tertiary">{provider.id}</p></div>
        <span className={`text-sm font-medium ${state === "ready" || state === "serving" ? "text-accent-green" : "text-text-secondary"}`}>{stateLabel}</span>
      </div>
      <p className="mt-4 text-sm leading-6 text-text-secondary">{providerRouteReason(provider)}</p>
      <div className="mt-6 grid gap-7 lg:grid-cols-2 lg:gap-10">
        <section aria-label="Machine capability"><h4 className="text-sm font-semibold text-text-primary">Hardware</h4>
          <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-5">
            <DetailMetric label="Memory" value={`${provider.memory_gb.toLocaleString()} GB`} />
            <DetailMetric label="GPU" value={`${provider.gpu_cores} cores`} />
            <DetailMetric label="CPU" value={`${provider.cpu_cores.performance} performance + ${provider.cpu_cores.efficiency} efficiency`} />
            <DetailMetric label="Memory bandwidth" value={`${provider.memory_bandwidth_gbs.toLocaleString()} GB/s`} />
          </dl>
        </section>
        <section aria-label="Provider activity"><h4 className="text-sm font-semibold text-text-primary">Activity</h4>
          <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-5">
            <DetailMetric label="Requests served" value={formatCompactNumber(provider.requests_served)} />
            <DetailMetric label="Tokens generated" value={formatCompactNumber(provider.tokens_generated)} />
            <DetailMetric label="Reported generation speed" value={provider.decode_tps > 0 ? `${Math.round(provider.decode_tps)} tok/s` : "—"} />
            <DetailMetric label="Loaded model" value={provider.current_model ? shortProviderModel(provider.current_model) : "None loaded"} />
          </dl>
        </section>
      </div>
      <div className="mt-7 grid gap-7 border-t border-border-dim pt-6 lg:grid-cols-2 lg:gap-10">
        <section aria-label="Model coverage"><h4 className="text-sm font-semibold text-text-primary">Advertised models <span className="ml-1.5 font-normal text-text-tertiary">{models.length}</span></h4>
          {models.length === 0 ? <p className="mt-3 text-sm text-text-tertiary">No model list reported.</p> : <ul className="mt-3 space-y-2 text-sm leading-5 text-text-secondary">{models.map((model) => <li key={model}>{shortProviderModel(model)}</li>)}</ul>}
        </section>
        <section aria-label="Attestation status"><h4 className="flex items-center gap-2 text-sm font-semibold text-text-primary"><ShieldCheck size={16} className="text-text-tertiary" />Attestation</h4>
          <dl className="mt-4 grid grid-cols-2 gap-x-6 gap-y-5">
            <DetailMetric label="Trust level" value={provider.trust_level === "hardware" ? "Hardware backed" : "Basic identity"} />
            <DetailMetric label="Apple device attestation" value={certificate} />
            <DetailMetric label="Last routing challenge" value={relativeChallengeLabel(provider.last_challenge_verified)} />
            <DetailMetric label="Device identity" value="Private" />
          </dl>
        </section>
      </div>
    </article>
  );
}
