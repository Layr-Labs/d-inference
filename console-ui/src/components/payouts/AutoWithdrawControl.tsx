"use client";

import { CalendarClock, Loader2 } from "lucide-react";

export function formatAutoWithdrawNextAt(value?: string | null): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZone: "UTC",
    timeZoneName: "short",
  }).format(date);
}

export function AutoWithdrawControl({
  enabled,
  nextAt,
  loading,
  canEnable,
  onChange,
}: {
  enabled: boolean;
  nextAt?: string | null;
  loading: boolean;
  canEnable: boolean;
  onChange: (enabled: boolean) => void;
}) {
  const nextLabel = formatAutoWithdrawNextAt(nextAt);
  const disabled = loading || (!enabled && !canEnable);
  let scheduleLabel = "Enabled - next check is being scheduled";
  if (!canEnable) {
    scheduleLabel = "Paused - automatic withdrawals resume when Stripe payouts are ready";
  } else if (nextLabel) {
    scheduleLabel = `Next check: ${nextLabel}`;
  }

  return (
    <div className="mt-4 rounded-lg border border-border-dim bg-bg-primary p-3">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <CalendarClock size={14} className="shrink-0 text-teal" />
            <p className="text-sm font-medium text-text-primary">
              Automatic weekly withdrawals
            </p>
          </div>
          <p className="mt-1 text-xs leading-relaxed text-text-tertiary">
            Every Monday at 09:00 UTC, if at least $1 is available, send all
            whole-cent earnings through Stripe&apos;s free standard payout. Any
            sub-cent remainder stays in your balance.
          </p>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={enabled}
          aria-label="Automatic weekly withdrawals"
          disabled={disabled}
          onClick={() => onChange(!enabled)}
          className={`relative mt-0.5 h-6 w-11 shrink-0 rounded-full border transition-colors ${
            enabled
              ? "border-teal bg-teal"
              : "border-border-dim bg-bg-secondary"
          } disabled:cursor-not-allowed disabled:opacity-50`}
        >
          <span
            className={`absolute left-0.5 top-0.5 h-4 w-4 rounded-full bg-white shadow-sm transition-transform ${
              enabled ? "translate-x-5" : "translate-x-0"
            }`}
          />
          {loading && (
            <Loader2
              size={12}
              aria-hidden="true"
              className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 animate-spin text-ink"
            />
          )}
        </button>
      </div>
      {enabled && (
        <p className="mt-2 text-xs font-mono text-teal">
          {scheduleLabel}
        </p>
      )}
      {!enabled && !canEnable && (
        <p className="mt-2 text-xs text-text-tertiary">
          Finish Stripe payout setup before enabling.
        </p>
      )}
      {enabled && (
        <p className="mt-1 text-[11px] text-text-tertiary">
          Turning this off stops future withdrawals. A payout already in progress will still complete.
        </p>
      )}
    </div>
  );
}
