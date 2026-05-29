"use client";

import { Key, Loader2, Pencil, Power, RefreshCw, Trash2 } from "lucide-react";
import type { ApiKey } from "@/lib/api";
import {
  formatCount,
  formatUsd,
  isExpired,
  keyStatus,
  relativeTime,
  usageBarColor,
  windowLabel,
} from "./format";

// Small monospaced pill used for the reset window and per-minute overrides.
function KeyChip({ label }: { label: string }) {
  return (
    <span className="text-[10px] font-mono uppercase tracking-wide text-text-tertiary bg-bg-tertiary border border-border-dim rounded px-1.5 py-0.5">
      {label}
    </span>
  );
}

// Usage-vs-limit progress bar (or an "Unlimited" track when uncapped).
function UsageBar({ keyData }: { keyData: ApiKey }) {
  const limited = keyData.limit_usd != null && keyData.limit_usd > 0;
  const pct = limited ? Math.min(100, (keyData.usage_usd / (keyData.limit_usd as number)) * 100) : 0;
  const barColor = usageBarColor(pct);

  return (
    <div className="mt-3">
      <div className="flex items-center justify-between mb-1.5 text-xs">
        <span className="text-text-tertiary">
          {limited ? (
            <>
              <span className="font-mono text-text-secondary">{formatUsd(keyData.usage_usd, 4)}</span>
              {" / "}
              <span className="font-mono">{formatUsd(keyData.limit_usd as number)}</span>
            </>
          ) : (
            <>
              <span className="font-mono text-text-secondary">{formatUsd(keyData.usage_usd, 4)}</span>
              {" used · Unlimited"}
            </>
          )}
        </span>
        <KeyChip label={windowLabel(keyData.limit_reset)} />
      </div>
      <div className="h-1.5 rounded-full bg-bg-tertiary overflow-hidden">
        {limited ? (
          <div className={`h-full rounded-full ${barColor}`} style={{ width: `${pct}%` }} />
        ) : (
          <div className="h-full rounded-full bg-border-subtle/40" style={{ width: "100%" }} />
        )}
      </div>
    </div>
  );
}

// Icon-only row action button (enable/disable, edit, rotate, delete).
function IconAction({
  icon: Icon,
  title,
  onClick,
  disabled,
  danger,
}: {
  icon: typeof Key;
  title: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      aria-label={title}
      className={`p-2 rounded-lg hover:bg-bg-hover transition-colors disabled:opacity-40 ${
        danger ? "text-text-tertiary hover:text-accent-red" : "text-text-tertiary hover:text-text-secondary"
      }`}
    >
      <Icon size={15} />
    </button>
  );
}

// KeyCard renders one API key: name, status, usage bar, timestamps, limit chips,
// and the per-key actions.
export function KeyCard({
  keyData,
  isConsole,
  busy,
  onToggle,
  onEdit,
  onRotate,
  onDelete,
}: {
  keyData: ApiKey;
  isConsole: boolean;
  busy: boolean;
  onToggle: () => void;
  onEdit: () => void;
  onRotate: () => void;
  onDelete: () => void;
}) {
  const status = keyStatus(keyData);
  const hasOverrides =
    !!keyData.rpm_limit ||
    !!keyData.itpm_limit ||
    !!keyData.otpm_limit ||
    (keyData.allowed_models?.length ?? 0) > 0;

  return (
    <div className="rounded-xl border border-border-dim bg-bg-white p-4 shadow-sm">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-sm font-semibold text-text-primary truncate">{keyData.name || "Untitled key"}</span>
            <span
              className={`text-[10px] font-mono uppercase tracking-wide rounded border px-1.5 py-0.5 ${status.cls}`}
            >
              {status.label}
            </span>
            {isConsole && (
              <span className="text-[10px] font-mono uppercase tracking-wide text-coral bg-coral-light border border-coral/30 rounded px-1.5 py-0.5">
                Console key
              </span>
            )}
          </div>
          <p className="mt-1 text-xs font-mono text-text-tertiary truncate">{keyData.label}</p>
        </div>
        <div className="flex items-center shrink-0">
          {busy ? (
            <Loader2 size={15} className="animate-spin text-text-tertiary m-2" />
          ) : (
            <>
              <IconAction
                icon={Power}
                title={keyData.disabled ? "Enable key" : "Disable key"}
                onClick={onToggle}
              />
              <IconAction icon={Pencil} title="Edit limits" onClick={onEdit} />
              <IconAction icon={RefreshCw} title="Rotate secret" onClick={onRotate} />
              <IconAction icon={Trash2} title="Revoke key" onClick={onDelete} danger />
            </>
          )}
        </div>
      </div>

      <UsageBar keyData={keyData} />

      <div className="mt-3 flex items-center gap-2 flex-wrap">
        <span className="text-xs text-text-tertiary">
          Last used <span className="text-text-secondary">{relativeTime(keyData.last_used_at)}</span>
        </span>
        <span className="text-text-tertiary/40">·</span>
        <span className="text-xs text-text-tertiary">
          Created <span className="text-text-secondary">{relativeTime(keyData.created_at)}</span>
        </span>
        {keyData.expires_at && (
          <>
            <span className="text-text-tertiary/40">·</span>
            <span className="text-xs text-text-tertiary">
              {isExpired(keyData) ? "Expired " : "Expires "}
              <span className="text-text-secondary">{new Date(keyData.expires_at).toLocaleDateString()}</span>
            </span>
          </>
        )}
      </div>

      {hasOverrides && (
        <div className="mt-3 flex items-center gap-1.5 flex-wrap">
          {keyData.rpm_limit ? <KeyChip label={`RPM ${formatCount(keyData.rpm_limit)}`} /> : null}
          {keyData.itpm_limit ? <KeyChip label={`ITPM ${formatCount(keyData.itpm_limit)}`} /> : null}
          {keyData.otpm_limit ? <KeyChip label={`OTPM ${formatCount(keyData.otpm_limit)}`} /> : null}
          {keyData.allowed_models && keyData.allowed_models.length > 0 ? (
            <span
              title={keyData.allowed_models.join(", ")}
              className="text-[10px] font-mono uppercase tracking-wide text-accent-brand bg-accent-brand-dim border border-accent-brand/25 rounded px-1.5 py-0.5"
            >
              {keyData.allowed_models.length} model{keyData.allowed_models.length === 1 ? "" : "s"}
            </span>
          ) : null}
        </div>
      )}
    </div>
  );
}
