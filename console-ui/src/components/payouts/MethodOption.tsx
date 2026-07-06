"use client";

// A withdrawal-speed option (Standard / Instant) in the Stripe withdraw modal.
// Shared by billing + earnings (previously byte-identical in both — F3).
export function MethodOption({
  selected,
  onClick,
  disabled,
  icon,
  label,
  eta,
  fee,
  tooltip,
}: {
  selected: boolean;
  onClick: () => void;
  disabled?: boolean;
  icon: React.ReactNode;
  label: string;
  eta: string;
  fee: string;
  tooltip?: string;
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={tooltip}
      className={`flex items-center justify-between gap-3 px-3 py-3 rounded-lg border-2 transition-all text-left ${
        selected
          ? "bg-blue/10 border-blue text-blue"
          : disabled
          ? "bg-bg-primary border-border-dim text-text-tertiary cursor-not-allowed opacity-60"
          : "bg-bg-primary border-border-dim text-text-secondary hover:border-blue/30 hover:text-blue"
      }`}
    >
      <div className="flex items-center gap-3">
        {icon}
        <div>
          <div className="text-sm font-semibold">{label}</div>
          <div className="text-xs font-mono text-text-tertiary">{eta}</div>
        </div>
      </div>
      <div className="text-xs font-mono">{fee}</div>
    </button>
  );
}
