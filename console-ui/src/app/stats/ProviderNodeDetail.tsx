"use client";

import { useEffect, useState, type ReactNode } from "react";
import {
  Activity,
  CheckCircle2,
  Clock,
  Cpu,
  HardDrive,
  Layers,
  Loader2,
  Server,
  ShieldCheck,
  XCircle,
  Zap,
} from "lucide-react";
import type { CertVerificationResult, VerificationStep } from "@/lib/cert-verify";
import {
  compactProviderId,
  isProviderRoutable,
  providerRouteReason,
  providerRouteState,
  relativeChallengeLabel,
  shortProviderModel,
  type ProviderStats,
} from "./provider-fleet";

interface ProviderAttestation {
  provider_id: string;
  trust_level: string;
  status: string;
  serial_number?: string;
  mda_cert_chain_b64?: string[];
  mda_serial?: string;
}

function formatCompact(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}K`;
  return value.toLocaleString();
}

function maskSerial(serial?: string): string {
  if (!serial) return "Hidden";
  if (serial.length <= 7) return serial;
  return `${serial.slice(0, 4)}…${serial.slice(-3)}`;
}

function DetailMetric({ label, value, icon }: { label: string; value: string; icon: ReactNode }) {
  return (
    <div className="min-w-0 rounded-lg border border-border-dim bg-bg-primary/55 px-3 py-2">
      <div className="flex items-center gap-1.5 text-text-tertiary">
        {icon}
        <p className="text-[9px] font-mono uppercase tracking-wider">{label}</p>
      </div>
      <p className="mt-1 break-words font-mono text-sm font-semibold leading-5 text-text-primary">{value}</p>
    </div>
  );
}

function VerifyStepLine({ step }: { step: VerificationStep }) {
  let icon = <Clock size={12} className="text-text-tertiary" />;
  if (step.status === "success") icon = <CheckCircle2 size={12} className="text-accent-green" />;
  if (step.status === "error") icon = <XCircle size={12} className="text-accent-red" />;
  if (step.status === "running") icon = <Loader2 size={12} className="animate-spin text-accent-brand" />;
  return (
    <div className="flex gap-2 py-1.5">
      <div className="mt-0.5 shrink-0">{icon}</div>
      <div className="min-w-0">
        <p className="text-xs text-text-secondary">{step.label}</p>
        {step.detail && <p className="mt-0.5 break-words font-mono text-[10px] text-text-tertiary">{step.detail}</p>}
      </div>
    </div>
  );
}

function RouteVerdict({ provider }: { provider: ProviderStats }) {
  const state = providerRouteState(provider);
  const ready = state !== "attention";
  let title = "Needs attention";
  if (state === "serving") title = "Serving traffic now";
  if (state === "ready") title = "Ready for a request";
  return (
    <div className={`mt-4 border-l-4 px-3 py-3 ${ready ? "border-accent-green bg-accent-green/10" : "border-accent-amber bg-accent-amber-dim"}`}>
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className={`text-sm font-semibold ${ready ? "text-accent-green" : "text-accent-amber"}`}>{title}</p>
          <p className="mt-1 text-[11px] leading-4 text-text-secondary">{providerRouteReason(provider)}</p>
        </div>
        <span className="shrink-0 font-mono text-[10px] uppercase tracking-wider text-text-tertiary">
          {isProviderRoutable(provider) ? "admitted" : "excluded"}
        </span>
      </div>
    </div>
  );
}

async function checkProviderCertificate(
  provider: ProviderStats,
  onSteps: (steps: VerificationStep[]) => void,
): Promise<{ result: CertVerificationResult; attestation: ProviderAttestation | null }> {
  const response = await fetch("/api/attestation");
  if (!response.ok) throw new Error(`Attestation API returned HTTP ${response.status}`);
  const data = await response.json();
  const attestedProviders: ProviderAttestation[] = data.providers ?? [];
  const matched =
    attestedProviders.find((entry) => entry.provider_id === provider.id) ??
    attestedProviders.find((entry) => entry.provider_id?.startsWith(provider.id)) ??
    null;
  if (!matched) {
    return {
      result: { success: false, steps: [], error: "Node was not present in the public attestation feed." },
      attestation: null,
    };
  }
  const certs = matched.mda_cert_chain_b64 ?? [];
  if (certs.length < 2) {
    return {
      result: {
        success: false,
        steps: [{ status: "error", label: "Certificate chain incomplete", detail: `Found ${certs.length}; at least 2 certificates are required.` }],
        error: "This node does not have a complete Apple certificate chain yet.",
      },
      attestation: matched,
    };
  }
  const { verifyCertificateChain } = await import("@/lib/cert-verify");
  return { result: await verifyCertificateChain(certs, onSteps), attestation: matched };
}

function certificatePresentation(result: CertVerificationResult | null, available?: boolean) {
  if (result?.success) return { label: "Apple certificate verified", color: "text-accent-green" };
  if (result) return { label: "Certificate check failed", color: "text-accent-red" };
  if (available) return { label: "Proof available", color: "text-text-tertiary" };
  return { label: "No proof published", color: "text-text-tertiary" };
}

export function ProviderNodeDetail({ provider }: { provider: ProviderStats | null }) {
  const [verifying, setVerifying] = useState(false);
  const [verifySteps, setVerifySteps] = useState<VerificationStep[]>([]);
  const [verifyResult, setVerifyResult] = useState<CertVerificationResult | null>(null);
  const [attestation, setAttestation] = useState<ProviderAttestation | null>(null);

  useEffect(() => {
    setVerifySteps([]);
    setVerifyResult(null);
    setAttestation(null);
    setVerifying(false);
  }, [provider?.id]);

  if (!provider) {
    return (
      <div className="rounded-xl border border-dashed border-border-subtle bg-bg-secondary p-6 text-sm text-text-tertiary">
        Select a node to inspect its routing state, hardware, models, and certificate proof.
      </div>
    );
  }

  async function verifyCertificate() {
    if (!provider) return;
    setVerifying(true);
    setVerifySteps([]);
    setVerifyResult(null);
    setAttestation(null);
    try {
      const check = await checkProviderCertificate(provider, setVerifySteps);
      setAttestation(check.attestation);
      setVerifyResult(check.result);
    } catch (error) {
      setVerifyResult({ success: false, steps: [], error: error instanceof Error ? error.message : String(error) });
    } finally {
      setVerifying(false);
    }
  }

  const models = provider.models ?? [];
  const certCount = attestation?.mda_cert_chain_b64?.length ?? 0;
  const verifiedSerial = verifyResult?.deviceInfo?.serial || attestation?.mda_serial || attestation?.serial_number;
  const certificate = certificatePresentation(verifyResult, provider.certificate_available);

  return (
    <article className="overflow-hidden rounded-xl border border-border-dim bg-bg-secondary shadow-sm">
      <div className="p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <Server size={15} className="shrink-0 text-accent-brand" />
              <h3 className="truncate text-base font-semibold text-text-primary">{provider.chip}</h3>
            </div>
            <p className="mt-1 font-mono text-[10px] text-text-tertiary">
              {provider.machine_model || "Apple Silicon"} · {compactProviderId(provider.id)}
            </p>
          </div>
          <span className={`rounded-full px-2 py-1 text-[9px] font-mono uppercase tracking-wider ${provider.trust_level === "hardware" ? "bg-accent-green/10 text-accent-green" : "bg-bg-elevated text-text-tertiary"}`}>
            {provider.trust_level === "hardware" ? "Hardware trust" : "Basic identity"}
          </span>
        </div>

        <RouteVerdict provider={provider} />

        <div className="mt-4">
          <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">Machine capability</p>
          <div className="mt-2 grid grid-cols-2 gap-2">
            <DetailMetric label="Memory" value={`${provider.memory_gb} GB`} icon={<HardDrive size={11} />} />
            <DetailMetric label="GPU" value={`${provider.gpu_cores} cores`} icon={<Cpu size={11} />} />
            <DetailMetric label="CPU" value={`${provider.cpu_cores.performance}P + ${provider.cpu_cores.efficiency}E`} icon={<Activity size={11} />} />
            <DetailMetric label="Bandwidth" value={`${provider.memory_bandwidth_gbs} GB/s`} icon={<Zap size={11} />} />
          </div>
        </div>

        <div className="mt-4 grid grid-cols-3 gap-2 rounded-lg border border-border-dim bg-bg-primary/55 p-3">
          <div>
            <p className="text-[9px] font-mono uppercase text-text-tertiary">Requests served</p>
            <p className="mt-1 font-mono text-sm font-semibold text-text-primary">{formatCompact(provider.requests_served)}</p>
          </div>
          <div>
            <p className="text-[9px] font-mono uppercase text-text-tertiary">Tokens generated</p>
            <p className="mt-1 font-mono text-sm font-semibold text-text-primary">{formatCompact(provider.tokens_generated)}</p>
          </div>
          <div>
            <p className="text-[9px] font-mono uppercase text-text-tertiary">Reported speed</p>
            <p className="mt-1 font-mono text-sm font-semibold text-text-primary">{provider.decode_tps > 0 ? `${Math.round(provider.decode_tps)} tok/s` : "—"}</p>
          </div>
        </div>

        <div className="mt-4">
          <div className="flex items-center justify-between gap-3">
            <div className="flex items-center gap-1.5">
              <Layers size={12} className="text-accent-brand" />
              <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">Model coverage</p>
            </div>
            <p className="text-[10px] font-mono text-text-tertiary">{models.length} advertised</p>
          </div>
          {provider.current_model && (
            <div className="mt-2 rounded-lg border border-accent-brand/20 bg-accent-brand/5 px-3 py-2">
              <p className="text-[9px] font-mono uppercase tracking-wider text-accent-brand">Loaded now</p>
              <p className="mt-1 truncate text-xs font-medium text-text-primary">{shortProviderModel(provider.current_model)}</p>
            </div>
          )}
          <div className="mt-2 flex flex-wrap gap-1.5">
            {models.length === 0 ? (
              <span className="text-xs text-text-tertiary">No model list reported.</span>
            ) : models.map((model) => (
              <span key={model} className="rounded-md bg-bg-primary px-2 py-1 font-mono text-[10px] text-text-secondary">
                {shortProviderModel(model)}
              </span>
            ))}
          </div>
        </div>
      </div>

      <div className="border-t border-border-dim bg-bg-primary/45 p-4">
        <div className="flex items-start justify-between gap-3">
          <div>
            <div className="flex items-center gap-1.5">
              <ShieldCheck size={13} className="text-accent-brand" />
              <p className="text-xs font-semibold text-text-primary">Independent certificate check</p>
            </div>
            <p className={`mt-1 font-mono text-[10px] ${certificate.color}`}>
              {certificate.label}
            </p>
          </div>
          <button
            type="button"
            onClick={verifyCertificate}
            disabled={verifying}
            className="inline-flex shrink-0 items-center gap-1.5 rounded-lg bg-accent-brand px-3 py-2 text-xs font-medium text-white transition-opacity hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-55"
          >
            {verifying ? <Loader2 size={12} className="animate-spin" /> : <ShieldCheck size={12} />}
            Check proof
          </button>
        </div>
        <div className="mt-3 grid grid-cols-3 gap-2 font-mono text-[10px]">
          <div><p className="text-text-tertiary">Route challenge</p><p className="mt-1 text-text-primary">{relativeChallengeLabel(provider.last_challenge_verified)}</p></div>
          <div><p className="text-text-tertiary">Certificates</p><p className="mt-1 text-text-primary">{certCount || (provider.certificate_available ? "Available" : "None")}</p></div>
          <div><p className="text-text-tertiary">Serial</p><p className="mt-1 text-text-primary">{maskSerial(verifiedSerial)}</p></div>
        </div>
        {(verifySteps.length > 0 || verifyResult?.error) && (
          <div className="mt-3 border-t border-border-dim pt-2">
            {verifySteps.map((step) => <VerifyStepLine key={step.label} step={step} />)}
            {verifyResult?.error && <p className="mt-2 rounded-md bg-accent-red/5 px-2 py-1.5 text-[11px] text-accent-red">{verifyResult.error}</p>}
          </div>
        )}
      </div>
    </article>
  );
}
