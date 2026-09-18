import { AlertCircle } from "lucide-react";

export function GeographyNotice({ locationsUnavailable, flowsUnavailable }: {
  locationsUnavailable: boolean;
  flowsUnavailable: boolean;
}) {
  if (!locationsUnavailable && !flowsUnavailable) return null;
  const subject = locationsUnavailable ? "Request locations" : "Request routes";
  return (
    <div role="status" aria-label="Geography availability" className="mx-5 mt-4 flex items-start gap-2.5 rounded-lg border border-accent-amber/25 bg-accent-amber-dim px-4 py-3 text-sm text-text-primary sm:mx-7">
      <AlertCircle size={17} className="mt-0.5 shrink-0 text-accent-amber" aria-hidden="true" />
      <p>{subject} are temporarily unavailable. Other network stats are still available. We’ll retry automatically.</p>
    </div>
  );
}
