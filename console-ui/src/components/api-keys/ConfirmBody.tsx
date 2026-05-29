"use client";

import { Loader2 } from "lucide-react";

// ConfirmBody is the contents of a confirm dialog (rendered inside <Modal>).
export function ConfirmBody({
  message,
  confirmLabel,
  danger,
  busy,
  onConfirm,
  onCancel,
}: {
  message: string;
  confirmLabel: string;
  danger?: boolean;
  busy: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <div className="space-y-5">
      <p className="text-sm text-text-secondary leading-relaxed">{message}</p>
      <div className="flex gap-3">
        <button
          onClick={onCancel}
          disabled={busy}
          className="flex-1 py-2.5 rounded-lg border border-border-dim text-text-secondary text-sm font-medium hover:bg-bg-hover transition-colors disabled:opacity-50"
        >
          Cancel
        </button>
        <button
          onClick={onConfirm}
          disabled={busy}
          className={`flex-1 py-2.5 rounded-lg text-white text-sm font-semibold hover:opacity-90 transition-all disabled:opacity-50 flex items-center justify-center gap-2 ${
            danger ? "bg-accent-red" : "bg-coral"
          }`}
        >
          {busy && <Loader2 size={14} className="animate-spin" />}
          {confirmLabel}
        </button>
      </div>
    </div>
  );
}
