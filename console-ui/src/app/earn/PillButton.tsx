"use client";

export function PillButton({
  label,
  selected,
  onClick,
}: {
  label: string;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`px-4 py-2.5 rounded-lg text-sm font-medium transition-all ${
        selected
          ? "bg-accent-brand text-white shadow-sm"
          : "bg-bg-tertiary text-text-secondary hover:bg-bg-hover hover:text-text-primary"
      }`}
    >
      {label}
    </button>
  );
}
