// Whether this Mac can serve on Darkbloom. A runtime that evaluates eligibility natively
// includes it in every snapshot; when it is absent the renderer derives only the checks the
// snapshot itself supports.
export interface Eligibility {
  // False when any check failed, or when an unevaluated check blocks the decision.
  eligible: boolean;
  checked_at: number;
  checks: EligibilityCheck[];
}
export interface EligibilityCheck {
  // Known IDs: apple_silicon, memory, macos, storage, security. Others are shown as given.
  id: string;
  label: string;
  // null when the check could not be evaluated.
  ok: boolean | null;
  // What was observed, e.g. "64 GB".
  value?: string;
  // Plain-language reason for a failed or unevaluated check, and what would satisfy it.
  detail?: string;
}
// Asks to be emailed when this Mac can join. `reasons` are the IDs of the failed checks.
export interface WaitlistAction {
  action: 'waitlist';
  email: string;
  reasons: string[];
}
