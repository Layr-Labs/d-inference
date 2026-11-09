// Feature waitlists (`darkbloom waitlist`): Darkbloom opens some features, such as clusters and
// Darkbloom Sandbox, to the accounts it approves from a waitlist per feature. A waitlist is per
// account, not per Mac. Not the eligibility sign-up of an ineligible Mac (`WaitlistAction`).

// One waitlist and where the account stands (docs/provider/cli-reference.md#darkbloom-waitlist).
export interface WaitlistEntry {
  // The waitlist's id, such as `cluster` or `sandbox`.
  feature: string;
  title: string;
  summary?: string | null;
  // The command that starts the feature once approved, such as `darkbloom cluster`.
  start_command?: string | null;
  status: 'none' | 'waitlisted' | 'approved' | 'revoked';
  // Place in line while waitlisted.
  position?: number | null;
  // ISO 8601.
  requested_at?: string | null;
  decided_at?: string | null;
}

// `GET /control/v1/waitlists`: `darkbloom waitlist --json`, in the coordinator's order.
export interface Waitlists {
  data: WaitlistEntry[];
  // Why the list is unavailable. `code` says what the person can do about it: `login` (link
  // this Mac's account), `none` (this coordinator has no waitlists), `unavailable` (anything else).
  error?: string;
  code?: 'login' | 'none' | 'unavailable';
}

// `darkbloom waitlist <feature> --json`: joins (or keeps the place) and returns the entry.
export interface WaitlistJoinAction {
  action: 'waitlist_join';
  feature: string;
}
