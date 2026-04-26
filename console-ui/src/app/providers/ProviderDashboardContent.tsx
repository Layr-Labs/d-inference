"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import {
  Activity,
  AlertTriangle,
  ArrowRight,
  CheckCircle2,
  ChevronDown,
  Cpu,
  ExternalLink,
  HardDrive,
  Info,
  Loader2,
  Mail,
  RefreshCw,
  ShieldCheck,
  TrendingUp,
  Wallet,
  XCircle,
  Zap,
} from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import type {
  MyProvider,
  MyProvidersResponse,
  MySummaryResponse,
} from "./types";
import {
  computeWarnings,
  highestSeverity,
  type Warning,
  type WarningSeverity,
} from "./warnings";

const REFRESH_MS = 15_000;

function formatUSD(microUSD: number): string {
  return `$${(microUSD / 1_000_000).toFixed(microUSD < 10_000 ? 4 : 2)}`;
}

function formatRelative(iso?: string): string {
  if (!iso) return "never";
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "never";
  const seconds = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}

function maskSerial(serial: string): string {
  if (!serial) return "";
  if (serial.length <= 6) return serial;
  return serial.slice(0, 4) + "\u2022".repeat(serial.length - 6) + serial.slice(-2);
}

function formatNumber(n: number): string {
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(n);
}

function shortModelName(model: string): string {
  return model.split("/").pop() || model;
}

export default function ProviderDashboardContent() {
  const { ready, authenticated, login, getAccessToken } = useAuth();
  const [providersResp, setProvidersResp] = useState<MyProvidersResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchAll = useCallback(async () => {
    setRefreshing(true);
    setError(null);
    try {
      const token = await getAccessToken().catch(() => null);
      if (!token) {
        setError("Not authenticated");
        return;
      }
      const coordinatorUrl =
        localStorage.getItem("darkbloom_coordinator_url") ||
        process.env.NEXT_PUBLIC_COORDINATOR_URL ||
        "https://api.darkbloom.dev";
      const headers = { Authorization: `Bearer ${token}` };
      const pRes = await fetch(`${coordinatorUrl}/v1/me/providers`, { headers, cache: "no-store" });
      if (!pRes.ok) throw new Error(`providers: HTTP ${pRes.status}`);
      const p = await pRes.json() as MyProvidersResponse;
      setProvidersResp(p);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [getAccessToken]);

  useEffect(() => {
    if (!authenticated) {
      setLoading(false);
      return;
    }
    fetchAll();
    const id = setInterval(fetchAll, REFRESH_MS);
    return () => clearInterval(id);
  }, [authenticated, fetchAll]);

  if (!ready || (loading && authenticated)) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loader2 size={24} className="animate-spin text-accent-brand" />
      </div>
    );
  }

  if (!authenticated) {
    return (
      <div className="max-w-5xl mx-auto p-6">
        <div className="bg-bg-secondary rounded-lg p-6">
          <h1 className="text-2xl font-bold text-text-primary mb-2">Provider Dashboard</h1>
          <p className="text-sm text-text-secondary mb-5 max-w-2xl">
            Sign in to view your linked provider devices, earnings, health warnings, and routing status.
          </p>
          <button
            onClick={login}
            className="inline-flex items-center gap-2 px-6 py-2.5 rounded-lg bg-coral text-white font-medium text-sm hover:opacity-90"
          >
            <Mail size={14} />
            Sign In
          </button>
        </div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="max-w-5xl mx-auto p-6">
        <p className="text-accent-red text-sm">Failed to load: {error}</p>
        <button
          onClick={fetchAll}
          className="mt-3 inline-flex items-center gap-1.5 text-sm text-accent-brand hover:underline"
        >
          <RefreshCw size={14} /> Retry
        </button>
      </div>
    );
  }

  const providers = providersResp?.providers ?? [];

  return (
    <div className="max-w-6xl mx-auto p-6 space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-text-primary">Provider Dashboard</h1>
          <p className="text-sm text-text-tertiary mt-0.5">
            Your linked provider machines.
          </p>
        </div>
        <button
          onClick={fetchAll}
          disabled={refreshing}
          className="inline-flex items-center gap-1.5 text-sm text-text-tertiary hover:text-text-primary disabled:opacity-50"
        >
          <RefreshCw size={14} className={refreshing ? "animate-spin" : ""} /> Refresh
        </button>
      </div>

      <div className="rounded-lg border border-accent-brand/30 bg-accent-brand/5 p-4 flex items-start gap-3">
        <Info size={18} className="text-accent-brand shrink-0 mt-0.5" />
        <div>
          <p className="text-sm font-medium text-text-primary">
            We&apos;re rebuilding this page
          </p>
          <p className="text-sm text-text-secondary mt-1">
            Detailed machine stats, health, and routing info are coming soon. In the meantime, visit the{" "}
            <Link href="/earn" className="text-accent-brand hover:underline font-medium">
              Earnings page
            </Link>{" "}
            to see your provider details and payouts.
          </p>
        </div>
      </div>

      {providers.length === 0 ? (
        <OnboardingState />
      ) : (
        <div className="space-y-3">
          <h2 className="text-lg font-semibold text-text-primary">Registered Machines</h2>
          <div className="space-y-2">
            {providers.map((p) => (
              <SimpleMachineRow key={p.id} provider={p} />
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

function SummaryHeader({ summary }: { summary: MySummaryResponse }) {
  const cards = [
    {
      label: "Devices online",
      value: `${summary.counts.online + summary.counts.serving} of ${summary.counts.total}`,
      icon: Activity,
      sub: `${summary.counts.serving} serving`,
    },
    {
      label: "Needs attention",
      value: String(summary.counts.needs_attention),
      icon: AlertTriangle,
      sub: `${summary.counts.hardware} hardware trusted`,
    },
    {
      label: "Available earnings",
      value: formatUSD(summary.withdrawable_balance_micro_usd ?? summary.available_balance_micro_usd),
      icon: Wallet,
    },
    {
      label: "Lifetime earnings",
      value: formatUSD(summary.lifetime_micro_usd),
      sub: `${summary.lifetime_jobs.toLocaleString()} jobs`,
    },
    { label: "Last 7d", value: formatUSD(summary.last_7d_micro_usd), sub: `${summary.last_7d_jobs} jobs` },
    { label: "Last 24h", value: formatUSD(summary.last_24h_micro_usd), sub: `${summary.last_24h_jobs} jobs` },
  ];
  return (
    <div className="grid grid-cols-2 lg:grid-cols-6 gap-3">
      {cards.map(({ label, value, sub, icon: Icon }) => (
        <div key={label} className="rounded-lg bg-bg-secondary p-4">
          <div className="flex items-center gap-1.5 mb-1">
            {Icon ? <Icon size={12} className="text-text-tertiary" /> : null}
            <p className="text-xs text-text-tertiary">{label}</p>
          </div>
          <p className="text-xl font-bold text-text-primary">{value}</p>
          {sub && <p className="text-[11px] text-text-tertiary mt-0.5">{sub}</p>}
        </div>
      ))}
    </div>
  );
}

function PayoutBanner({ summary }: { summary: MySummaryResponse }) {
  if (summary.counts.total === 0) return null;
  if (summary.payout_ready || summary.wallet_address) return null;
  return (
    <div className="rounded-lg border border-accent-amber/40 bg-accent-amber/5 p-4 flex items-start gap-3">
      <AlertTriangle size={16} className="text-accent-amber shrink-0 mt-0.5" />
      <div className="flex-1">
        <p className="text-sm font-medium text-text-primary">Payout setup incomplete</p>
        <p className="text-xs text-text-secondary mt-0.5">
          Earnings are accruing, but withdrawals need a completed payout method.
        </p>
      </div>
      <Link
        href="/providers/earnings"
        className="text-xs font-medium text-accent-brand hover:underline whitespace-nowrap"
      >
        Set up payouts <ArrowRight size={11} className="inline" />
      </Link>
    </div>
  );
}

const POTENTIAL = [
  { machine: "M-series Mac, 32-64GB", fit: "Small and mid-size text models", note: "Good pilot node" },
  { machine: "Mac Studio, 96-128GB", fit: "Larger MoE models", note: "Higher routing capacity" },
  { machine: "Ultra-class, 192GB+", fit: "Premium large models", note: "Best earning ceiling" },
];

function OnboardingState() {
  return (
    <div className="bg-bg-secondary rounded-lg p-6">
      <div className="grid gap-6 lg:grid-cols-[1.1fr_0.9fr]">
        <div>
          <div className="inline-flex items-center gap-2 rounded-full bg-accent-brand/10 px-3 py-1 text-xs font-medium text-accent-brand mb-4">
            <TrendingUp size={13} />
            Earning potential
          </div>
          <h2 className="text-xl font-bold text-text-primary">No provider devices linked yet</h2>
          <p className="text-sm text-text-secondary mt-2 max-w-xl">
            Link an Apple Silicon Mac to start seeing live status, warnings, per-device earnings, and routing eligibility here.
          </p>

          <div className="grid gap-3 mt-5 sm:grid-cols-3">
            {POTENTIAL.map((item) => (
              <div key={item.machine} className="rounded-lg bg-bg-primary/60 p-3">
                <p className="text-xs font-semibold text-text-primary">{item.machine}</p>
                <p className="text-[11px] text-text-secondary mt-1">{item.fit}</p>
                <p className="text-[11px] text-text-tertiary mt-2">{item.note}</p>
              </div>
            ))}
          </div>

          <div className="flex flex-wrap gap-3 mt-6">
            <Link
              href="/providers/setup"
              className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-accent-brand text-white text-sm font-medium hover:bg-accent-brand-hover"
            >
              Set up a provider <ArrowRight size={14} />
            </Link>
            <Link
              href="/earn"
              className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-bg-tertiary text-text-primary text-sm font-medium hover:bg-bg-hover"
            >
              Open calculator <ArrowRight size={14} />
            </Link>
          </div>
        </div>

        <div className="space-y-3">
          {[
            { icon: Cpu, title: "Install", detail: "Download the provider CLI on your Mac." },
            { icon: ShieldCheck, title: "Link", detail: "Run darkbloom login and approve the device." },
            { icon: Zap, title: "Serve", detail: "Start the daemon and choose supported models." },
          ].map(({ icon: Icon, title, detail }) => (
            <div key={title} className="flex items-start gap-3 rounded-lg bg-bg-primary/60 p-3">
              <Icon size={16} className="text-accent-brand mt-0.5" />
              <div>
                <p className="text-sm font-semibold text-text-primary">{title}</p>
                <p className="text-xs text-text-secondary mt-0.5">{detail}</p>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function StatusPill({ status }: { status: string }) {
  const config: Record<string, { color: string; label: string }> = {
    serving: { color: "bg-accent-green text-white", label: "Serving" },
    online: { color: "bg-accent-green/20 text-accent-green", label: "Online" },
    offline: { color: "bg-text-tertiary/20 text-text-tertiary", label: "Offline" },
    untrusted: { color: "bg-accent-red/20 text-accent-red", label: "Untrusted" },
    never_seen: { color: "bg-text-tertiary/20 text-text-tertiary", label: "Never seen" },
  };
  const c = config[status] || { color: "bg-text-tertiary/20 text-text-tertiary", label: status };
  return (
    <span className={`inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[10px] font-semibold uppercase tracking-wider ${c.color}`}>
      <span className={`w-1.5 h-1.5 rounded-full ${status === "serving" || status === "online" ? "bg-accent-green" : "bg-current opacity-60"}`} />
      {c.label}
    </span>
  );
}

function severityChip(sev: WarningSeverity) {
  switch (sev) {
    case "blocking":
      return { color: "text-accent-red bg-accent-red/10", icon: XCircle };
    case "degrading":
      return { color: "text-accent-amber bg-accent-amber/10", icon: AlertTriangle };
    default:
      return { color: "text-accent-brand bg-accent-brand/10", icon: Info };
  }
}

function SimpleMachineRow({ provider }: { provider: MyProvider }) {
  const chipName = provider.hardware.chip_name || "Unknown chip";
  const memoryGB = provider.hardware.memory_gb ?? 0;

  return (
    <div className="rounded-lg bg-bg-secondary p-4 flex items-center justify-between gap-3">
      <div className="flex items-center gap-3 min-w-0">
        <div className="w-9 h-9 rounded-lg bg-accent-brand/10 flex items-center justify-center shrink-0">
          <Cpu size={18} className="text-accent-brand" />
        </div>
        <div className="min-w-0">
          <h3 className="text-sm font-semibold text-text-primary truncate">{chipName}</h3>
          <p className="text-xs text-text-tertiary truncate">
            {memoryGB} GB
            {provider.serial_number ? ` · ${maskSerial(provider.serial_number)}` : ""}
          </p>
        </div>
      </div>
      <div className="flex items-center gap-2 shrink-0">
        <StatusPill status={provider.status} />
        {provider.trust_level === "hardware" && (
          <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-green/10 text-accent-green text-[10px] font-semibold uppercase tracking-wider">
            <ShieldCheck size={10} /> Hardware
          </span>
        )}
      </div>
    </div>
  );
}

function MachineCard({ provider, ctx }: { provider: MyProvider; ctx: MyProvidersResponse }) {
  const warnings = useMemo(() => computeWarnings(provider, ctx), [provider, ctx]);
  const top = highestSeverity(warnings);
  const [showAttestation, setShowAttestation] = useState(false);
  const [showBackend, setShowBackend] = useState(false);

  const ringColor =
    top === "blocking"
      ? "border-accent-red/40"
      : top === "degrading"
        ? "border-accent-amber/40"
        : "border-transparent";

  const chipName = provider.hardware.chip_name || "Unknown chip";
  const memoryGB = provider.hardware.memory_gb ?? 0;
  const gpuCores = provider.hardware.gpu_cores ?? 0;

  return (
    <div className={`rounded-lg bg-bg-secondary overflow-hidden border ${ringColor}`}>
      <div className="p-4 flex flex-wrap items-start justify-between gap-3">
        <div className="flex items-center gap-3 min-w-0">
          <div className="w-10 h-10 rounded-lg bg-accent-brand/10 flex items-center justify-center shrink-0">
            <Cpu size={20} className="text-accent-brand" />
          </div>
          <div className="min-w-0">
            <h3 className="text-sm font-semibold text-text-primary truncate">{chipName}</h3>
            <p className="text-xs text-text-tertiary font-mono truncate">
              {provider.hardware.machine_model || provider.id}
              {provider.serial_number ? ` - ${maskSerial(provider.serial_number)}` : ""}
              {provider.version ? ` - v${provider.version}` : ""}
            </p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <StatusPill status={provider.status} />
          {provider.trust_level === "hardware" ? (
            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-green/10 text-accent-green text-[10px] font-semibold uppercase tracking-wider">
              <ShieldCheck size={10} /> Hardware
            </span>
          ) : provider.trust_level === "self_signed" ? (
            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-accent-amber/10 text-accent-amber text-[10px] font-semibold uppercase tracking-wider">
              Self-signed
            </span>
          ) : (
            <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-text-tertiary/20 text-text-tertiary text-[10px] font-semibold uppercase tracking-wider">
              Unverified
            </span>
          )}
        </div>
      </div>

      {warnings.length > 0 && (
        <div className="px-4 pb-3 space-y-1.5">
          {warnings.map((w) => (
            <WarningRow key={w.id} warning={w} />
          ))}
        </div>
      )}

      <div className="px-4 pb-4 grid grid-cols-2 md:grid-cols-4 gap-3 border-t border-border-dim/30 pt-3">
        <Stat label="Earnings" value={formatUSD(provider.earnings_total_micro_usd)} sub={`${provider.earnings_count} jobs`} />
        <Stat label="Memory" value={`${memoryGB} GB`} sub={`${gpuCores} GPU cores`} />
        <Stat
          label="Last seen"
          value={
            provider.last_heartbeat
              ? formatRelative(provider.last_heartbeat)
              : provider.last_seen
                ? formatRelative(provider.last_seen)
                : "never"
          }
        />
        <Stat
          label="Reputation"
          value={provider.reputation.score.toFixed(2)}
          sub={`${provider.reputation.successful_jobs}/${provider.reputation.total_jobs || 0} ok`}
        />
      </div>

      <div className="px-4 pb-3 grid grid-cols-2 md:grid-cols-4 gap-3">
        <Stat label="Requests" value={formatNumber(provider.lifetime_requests_served)} />
        <Stat label="Tokens" value={formatNumber(provider.lifetime_tokens_generated)} />
        <Stat label="Concurrency" value={`${provider.pending_requests} / ${provider.max_concurrency || 0}`} />
        <Stat
          label="Bandwidth"
          value={
            provider.hardware?.memory_bandwidth_gbs
              ? `${provider.hardware.memory_bandwidth_gbs} GB/s`
              : "not reported"
          }
        />
      </div>

      {provider.system_metrics && (
        <div className="px-4 pb-3 grid grid-cols-3 gap-3">
          <Stat label="Mem pressure" value={`${(provider.system_metrics.memory_pressure * 100).toFixed(0)}%`} />
          <Stat label="CPU usage" value={`${(provider.system_metrics.cpu_usage * 100).toFixed(0)}%`} />
          <Stat label="Thermal" value={provider.system_metrics.thermal_state} capitalize />
        </div>
      )}

      {(provider.warm_models?.length || provider.current_model) && (
        <div className="px-4 pb-3">
          <p className="text-xs text-text-tertiary mb-1.5">Models loaded</p>
          <div className="flex flex-wrap gap-1.5">
            {(provider.warm_models?.length ? provider.warm_models : provider.current_model ? [provider.current_model] : []).map((m) => (
              <span
                key={m}
                className={`px-2 py-0.5 rounded-md text-xs font-mono ${
                  m === provider.current_model
                    ? "bg-accent-brand/15 text-accent-brand"
                    : "bg-bg-tertiary text-text-secondary"
                }`}
              >
                {m.split("/").pop()}
                {m === provider.current_model ? " active" : ""}
              </span>
            ))}
          </div>
        </div>
      )}

      {provider.models.length > 0 && (
        <div className="px-4 pb-3">
          <p className="text-xs text-text-tertiary mb-1.5">Catalog models served ({provider.models.length})</p>
          <div className="flex flex-wrap gap-1.5">
            {provider.models.map((m) => (
              <span key={m.id} className="px-2 py-0.5 rounded-md bg-bg-tertiary text-xs text-text-secondary font-mono">
                {shortModelName(m.id)}
              </span>
            ))}
          </div>
        </div>
      )}

      <ExpandSection
        label="Trust & attestation"
        icon={ShieldCheck}
        open={showAttestation}
        onToggle={() => setShowAttestation(!showAttestation)}
      >
        <AttestationDetails p={provider} />
      </ExpandSection>

      {provider.backend_capacity && (
        <ExpandSection
          label="Backend slots"
          icon={Zap}
          open={showBackend}
          onToggle={() => setShowBackend(!showBackend)}
        >
          <BackendDetails p={provider} />
        </ExpandSection>
      )}
    </div>
  );
}

function Stat({ label, value, sub, capitalize }: { label: string; value: string; sub?: string; capitalize?: boolean }) {
  return (
    <div className="rounded-lg bg-bg-primary/50 p-2.5">
      <p className="text-xs text-text-tertiary mb-0.5">{label}</p>
      <p className={`text-sm font-semibold text-text-primary ${capitalize ? "capitalize" : ""}`}>{value}</p>
      {sub && <p className="text-[11px] text-text-tertiary mt-0.5">{sub}</p>}
    </div>
  );
}

function WarningRow({ warning }: { warning: Warning }) {
  const { color, icon: Icon } = severityChip(warning.severity);
  return (
    <div className={`flex items-start gap-2 p-2 rounded-lg ${color}`}>
      <Icon size={14} className="shrink-0 mt-0.5" />
      <div className="text-xs">
        <p className="font-medium">{warning.title}</p>
        <p className="opacity-80 mt-0.5">{warning.detail}</p>
      </div>
    </div>
  );
}

function ExpandSection({
  label,
  icon: Icon,
  open,
  onToggle,
  children,
}: {
  label: string;
  icon: typeof ShieldCheck;
  open: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <>
      <button
        onClick={onToggle}
        className="w-full flex items-center gap-2 px-4 py-2.5 border-t border-border-dim text-left hover:bg-bg-hover"
      >
        <Icon size={12} className="text-text-tertiary" />
        <span className="text-xs text-text-secondary">{label}</span>
        <ChevronDown size={12} className={`ml-auto text-text-tertiary transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open && <div className="px-4 py-3 border-t border-border-dim/50 space-y-3">{children}</div>}
    </>
  );
}

function CheckLine({ ok, label }: { ok: boolean; label: string }) {
  return (
    <div className="flex items-center gap-2 text-xs">
      {ok ? (
        <CheckCircle2 size={12} className="text-accent-green" />
      ) : (
        <XCircle size={12} className="text-accent-red" />
      )}
      <span className="text-text-secondary">{label}</span>
    </div>
  );
}

function AttestationDetails({ p }: { p: MyProvider }) {
  return (
    <>
      <div>
        <div className="flex items-center gap-1.5 mb-2">
          <ShieldCheck size={12} className="text-text-tertiary" />
          <span className="text-xs text-text-tertiary font-medium">Secure Enclave</span>
        </div>
        <div className="space-y-1">
          <CheckLine ok={p.secure_enclave} label="Hardware-bound P-256 identity" />
          <CheckLine ok={p.acme_verified} label="ACME device-attest-01" />
          <CheckLine ok={p.se_key_bound} label="SE key bound to MDA nonce" />
        </div>
      </div>

      <div>
        <div className="flex items-center gap-1.5 mb-2">
          <HardDrive size={12} className="text-text-tertiary" />
          <span className="text-xs text-text-tertiary font-medium">OS Security</span>
        </div>
        <div className="space-y-1">
          <CheckLine ok={p.sip_enabled} label="System Integrity Protection" />
          <CheckLine ok={p.secure_boot_enabled} label="Secure Boot" />
          <CheckLine ok={p.authenticated_root_enabled} label="Authenticated Root Volume" />
          <CheckLine ok={p.runtime_verified} label="Runtime hashes match manifest" />
        </div>
      </div>

      {p.mda_verified && (
        <div>
          <div className="flex items-center gap-1.5 mb-2">
            <ShieldCheck size={12} className="text-text-tertiary" />
            <span className="text-xs text-text-tertiary font-medium">Apple Device Attestation</span>
          </div>
          <div className="space-y-1 text-xs text-text-secondary">
            <CheckLine ok label="Apple CA cert chain verified" />
            {p.mda_serial && <div className="text-[11px] font-mono pl-5">Serial: {maskSerial(p.mda_serial)}</div>}
            {p.mda_os_version && <div className="text-[11px] pl-5">macOS {p.mda_os_version}</div>}
            {p.mda_sepos_version && <div className="text-[11px] pl-5">SEPOS {p.mda_sepos_version}</div>}
          </div>
        </div>
      )}

      {p.last_challenge_verified && (
        <div className="text-xs text-text-tertiary">
          Last attestation challenge: <span className="text-text-secondary">{formatRelative(p.last_challenge_verified)}</span>
          {p.failed_challenges > 0 && (
            <span className="ml-2 text-accent-amber">({p.failed_challenges} failed)</span>
          )}
        </div>
      )}

      {p.system_volume_hash && (
        <div>
          <p className="text-xs text-text-tertiary mb-1">System Volume Hash</p>
          <p className="text-xs font-mono text-text-tertiary break-all bg-bg-tertiary rounded px-2 py-1">
            {p.system_volume_hash}
          </p>
        </div>
      )}

      {p.mda_cert_chain_b64 && p.mda_cert_chain_b64.length > 0 && (
        <a
          href="https://www.apple.com/certificateauthority/private/"
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1 text-xs text-accent-brand hover:underline"
        >
          Verify against Apple Root CA <ExternalLink size={10} />
        </a>
      )}
    </>
  );
}

function BackendDetails({ p }: { p: MyProvider }) {
  const cap = p.backend_capacity!;
  return (
    <>
      <div className="grid grid-cols-3 gap-2 text-xs">
        <Stat label="GPU active" value={`${cap.gpu_memory_active_gb.toFixed(1)} GB`} />
        <Stat label="GPU peak" value={`${cap.gpu_memory_peak_gb.toFixed(1)} GB`} />
        <Stat label="Concurrency" value={`${p.pending_requests} / ${p.max_concurrency}`} />
      </div>
      {cap.slots.length > 0 && (
        <div className="space-y-1.5">
          {cap.slots.map((s) => (
            <div key={s.model} className="flex items-center justify-between rounded-md bg-bg-tertiary/50 px-2 py-1.5">
              <span className="text-xs font-mono text-text-secondary truncate">{s.model.split("/").pop()}</span>
              <div className="flex items-center gap-2 text-[11px]">
                <span
                  className={`px-1.5 py-0.5 rounded ${
                    s.state === "running"
                      ? "bg-accent-green/15 text-accent-green"
                      : s.state === "crashed"
                        ? "bg-accent-red/15 text-accent-red"
                        : s.state === "idle_shutdown"
                          ? "bg-accent-amber/15 text-accent-amber"
                          : "bg-text-tertiary/15 text-text-tertiary"
                  }`}
                >
                  {s.state}
                </span>
                <span className="text-text-tertiary">{s.num_running} run / {s.num_waiting} wait</span>
              </div>
            </div>
          ))}
        </div>
      )}
    </>
  );
}
