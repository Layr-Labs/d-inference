"use client";

// "Remove machine" affordance for an offline/retired card. Confirms,
// calls the ownership-checked coordinator DELETE via api.deleteProvider, toasts
// the result, and asks the parent to re-poll so the card disappears. Only shown
// for offline/never-seen machines — an online box would just re-register, and
// the coordinator refuses with 409 anyway, so we hide the affordance there to
// avoid a confusing dead end.

import { useState } from "react";
import { Trash2 } from "lucide-react";
import { useAuth } from "@/hooks/useAuth";
import { useToastStore } from "@/hooks/useToast";
import { deleteProvider } from "@/lib/api";
import type { MyProvider } from "../types";

export function RemoveMachineButton({
  provider,
  onRemoved,
}: {
  provider: MyProvider;
  onRemoved?: () => void;
}) {
  const { getAccessToken } = useAuth();
  const addToast = useToastStore((s) => s.addToast);
  const [removing, setRemoving] = useState(false);

  // The stable machine identity the coordinator's DELETE path resolves against.
  const serial = provider.serial_number || provider.id;
  const chipName = provider.hardware.chip_name || "this machine";

  async function handleRemove() {
    if (removing) return;
    const confirmed = window.confirm(
      `Remove ${chipName}? This deletes its record from your portal. Earnings history is preserved.`
    );
    if (!confirmed) return;

    setRemoving(true);
    try {
      const token = await getAccessToken();
      if (!token) {
        addToast("Sign in again to remove this machine.", "error");
        return;
      }
      await deleteProvider(token, serial);
      addToast("Machine removed.", "success");
      onRemoved?.();
    } catch (err) {
      addToast(err instanceof Error ? err.message : "Failed to remove machine.", "error");
    } finally {
      setRemoving(false);
    }
  }

  return (
    <button
      type="button"
      onClick={handleRemove}
      disabled={removing}
      aria-label="Remove machine"
      title="Remove this machine from your portal"
      className="inline-flex items-center gap-1 text-[11px] text-text-tertiary hover:text-accent-red disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
    >
      <Trash2 size={12} className={removing ? "animate-pulse" : ""} />
      {removing ? "Removing…" : "Remove"}
    </button>
  );
}
