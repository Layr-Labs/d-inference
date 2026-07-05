"use client";

import { X } from "lucide-react";

// The payout dialog shell (backdrop + close button, no title header). Shared by
// the Buy Credits / Withdraw modals on billing and earnings — previously a
// byte-identical local `Modal` in both files (proposal F3).
export function PayoutModal({
  open,
  onClose,
  children,
}: {
  open: boolean;
  onClose: () => void;
  children: React.ReactNode;
}) {
  if (!open) return null;
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm">
      <div className="bg-bg-white border border-border-dim rounded-xl w-full max-w-md mx-2 sm:mx-4 shadow-lg">
        <div className="flex justify-end p-3">
          <button
            onClick={onClose}
            className="p-1 rounded hover:bg-bg-hover text-text-tertiary"
          >
            <X size={16} />
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
