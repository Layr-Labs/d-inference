"use client";

import { ArrowLeft, Cpu, HardDrive, Layers, Shield, ShieldCheck, Zap } from "lucide-react";
import Link from "next/link";
import type { PublicProviderProfile } from "@/components/leaderboard/types";

function dotClass(status: string): string {
  if (status === "online" || status === "serving") return "bg-teal animate-pulse";
  if (status === "untrusted") return "bg-accent-amber";
  return "bg-text-quaternary";
}

function StatusDot({ status }: { status: string }) {
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className={`inline-block h-2 w-2 rounded-full ${dotClass(status)}`} />
      <span className="text-xs font-mono capitalize text-text-secondary">{status}</span>
    </span>
  );
}

function TrustChip({ trust }: { trust: string }) {
  if (trust === "hardware") {
    return (
      <span className="inline-flex items-center gap-1 rounded-full border border-teal/40 bg-teal/10 px-2 py-0.5 text-xs font-semibold text-teal">
        <ShieldCheck size={11} />
        Hardware Verified
      </span>
    );
  }
  if (trust === "self_signed") {
    return (
      <span className="inline-flex items-center gap-1 rounded-full border border-accent-brand/30 bg-accent-brand/10 px-2 py-0.5 text-xs font-semibold text-accent-brand">
        <Shield size={11} />
        Self-signed
      </span>
    );
  }
  return (
    <span className="inline-flex items-center gap-1 rounded-full border border-border-subtle bg-bg-elevated px-2 py-0.5 text-xs text-text-tertiary">
      <Shield size={11} />
      Unverified
    </span>
  );
}

function StatCard({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="rounded-lg border border-border-dim bg-bg-secondary px-4 py-3">
      <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">{label}</p>
      <p className="mt-1 font-mono text-lg font-semibold text-text-primary">{value}</p>
      {sub && <p className="text-[10px] font-mono text-text-tertiary">{sub}</p>}
    </div>
  );
}

function formatTokens(n: number): string {
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(1)}B`;
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}K`;
  return String(n);
}

function formatScore(score: number): string {
  return `${Math.round(score * 100)}%`;
}

export function PublicProviderProfileCard({ profile }: { profile: PublicProviderProfile }) {
  const hw = profile.hardware;
  const rep = profile.reputation;

  const chipLabel =
    hw.chip_name ||
    [hw.chip_family, hw.chip_tier].filter(Boolean).join(" ") ||
    "Unknown chip";

  return (
    <div className="mx-auto max-w-2xl px-4 py-8">
      {/* Back link */}
      <Link
        href="/leaderboard"
        className="mb-6 inline-flex items-center gap-1.5 text-sm text-text-tertiary hover:text-text-primary transition-colors"
      >
        <ArrowLeft size={14} />
        Back to Leaderboard
      </Link>

      {/* Header */}
      <div className="mb-6 flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="font-mono text-2xl font-bold text-text-primary">{profile.pseudonym}</h1>
          <div className="mt-2 flex flex-wrap items-center gap-2">
            <StatusDot status={profile.status} />
            <TrustChip trust={profile.trust_level} />
          </div>
        </div>
      </div>

      {/* Hardware */}
      <section className="mb-6">
        <h2 className="mb-3 text-xs font-mono uppercase tracking-wider text-text-tertiary">
          Hardware
        </h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <div className="flex items-center gap-2 rounded-lg border border-border-dim bg-bg-secondary px-4 py-3">
            <Cpu size={16} className="shrink-0 text-text-tertiary" />
            <div>
              <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">Chip</p>
              <p className="text-sm font-semibold text-text-primary">{chipLabel}</p>
            </div>
          </div>
          <div className="flex items-center gap-2 rounded-lg border border-border-dim bg-bg-secondary px-4 py-3">
            <HardDrive size={16} className="shrink-0 text-text-tertiary" />
            <div>
              <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
                Memory
              </p>
              <p className="text-sm font-semibold text-text-primary">
                {hw.memory_gb != null ? `${hw.memory_gb} GB` : "—"}
              </p>
            </div>
          </div>
          <div className="flex items-center gap-2 rounded-lg border border-border-dim bg-bg-secondary px-4 py-3">
            <Zap size={16} className="shrink-0 text-text-tertiary" />
            <div>
              <p className="text-[10px] font-mono uppercase tracking-wider text-text-tertiary">
                GPU Cores
              </p>
              <p className="text-sm font-semibold text-text-primary">
                {hw.gpu_cores != null ? hw.gpu_cores : "—"}
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Warm models */}
      {profile.warm_models.length > 0 && (
        <section className="mb-6">
          <h2 className="mb-3 text-xs font-mono uppercase tracking-wider text-text-tertiary">
            Warm Models
          </h2>
          <div className="flex flex-wrap gap-2">
            {profile.warm_models.map((m) => (
              <span
                key={m}
                className="inline-flex items-center gap-1.5 rounded-full border border-border-dim bg-bg-secondary px-3 py-1 font-mono text-xs text-text-primary"
              >
                <Layers size={11} className="text-text-tertiary" />
                {m}
              </span>
            ))}
          </div>
        </section>
      )}

      {/* Stats */}
      <section className="mb-6">
        <h2 className="mb-3 text-xs font-mono uppercase tracking-wider text-text-tertiary">
          Performance
        </h2>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <StatCard label="Reputation" value={formatScore(rep.score)} />
          <StatCard
            label="Jobs"
            value={String(rep.total_jobs)}
            sub={`${rep.successful_jobs} successful`}
          />
          <StatCard
            label="Avg TTFT"
            value={rep.avg_response_time_ms ? `${rep.avg_response_time_ms} ms` : "—"}
          />
          <StatCard
            label="Lifetime Tokens"
            value={formatTokens(profile.lifetime_tokens_generated)}
          />
        </div>
      </section>

      {/* Concurrency */}
      {profile.max_concurrency > 0 && (
        <p className="text-xs font-mono text-text-tertiary">
          Concurrency: <span className="text-text-primary">{profile.max_concurrency}</span> slot
          {profile.max_concurrency !== 1 ? "s" : ""}
        </p>
      )}
    </div>
  );
}
