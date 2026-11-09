// Feature waitlists (`darkbloom waitlist`): Darkbloom opens some features, such as clusters and
// Darkbloom Sandbox, to the accounts it approves from a waitlist per feature. A waitlist is per
// account, not per Mac. Not the eligibility sign-up of an ineligible Mac (`WaitlistAction`).
// The runtime offers both the resource and the action with the `waitlists` capability.

// One waitlist and where the account stands (docs/provider/cli-reference.md#darkbloom-waitlist).
export interface WaitlistEntry {
  // The waitlist's id, such as `cluster` or `sandbox`.
  feature: string;
  title: string;
  summary?: string | null;
  // The command that starts the feature once approved, such as `darkbloom cluster`, as the
  // coordinator lists it. The app shows it for a feature without a page of its own.
  start_command?: string | null;
  status: 'none' | 'waitlisted' | 'approved' | 'revoked';
  // Place in line while waitlisted.
  position?: number | null;
  // ISO 8601: when the account joined, and when Darkbloom approved or revoked it.
  requested_at?: string | null;
  decided_at?: string | null;
}

// `GET /control/v1/waitlists`: `darkbloom waitlist --json`, in the coordinator's order.
export interface Waitlists {
  data: WaitlistEntry[];
  // Why the list is unavailable, in the CLI's words. `code` says what the person can do about
  // it: `login` (link this Mac's account: no token, or one the coordinator refuses, 401 or 403),
  // `none` (this coordinator has no waitlists, 404), `unavailable` (anything else).
  error?: string;
  code?: 'login' | 'none' | 'unavailable';
}

// `darkbloom waitlist <feature> --json`: joins (or keeps the place) and returns the entry. A
// refusal fails the operation with the CLI's own message, which the app shows.
export interface WaitlistJoinAction {
  action: 'waitlist_join';
  feature: string;
}
