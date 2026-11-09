// Two-Mac clusters ("pairs"): the `cluster` resource, the actions that change a pair, and the
// guided setup session that drives `darkbloom cluster` / `darkbloom cluster local` with the app's
// own screens instead of a terminal.

// `GET /control/v1/cluster`: `darkbloom cluster status --json` (schema 1) as the runtime printed
// it. Every key is present; null when unknown. Keys are only ever added
// (docs/provider/cli-reference.md#darkbloom-cluster-status).
export interface ClusterStatus {
  schema: number;
  // This Mac holds a pairing; null when its pairing record couldn't be read.
  paired: boolean | null;
  role: 'leader' | 'member' | null;
  this_mac: string | null;
  other_mac: { name: string | null; answers: boolean | null } | null;
  model: { id: string; name: string | null } | null;
  // `tensor parallel`, `pipeline`, `pipeline with speculative decoding`, …
  mode: string | null;
  // Each Mac's share, such as `M3 Ultra 50% / M5 Max 50%`.
  split: string | null;
  serves: 'darkbloom' | 'local' | null;
  state: ClusterState;
  // Why it does not serve, in the CLI's words.
  reason: string | null;
  // What to do, in commands.
  next: string | null;
  // The status lines `darkbloom cluster` shows.
  lines: string[];
  service: { running: boolean; starts_at_login: boolean } | null;
  exit_code: number;
  // Set by the desktop API when the status could not be read at all (no runtime support, a
  // timeout, unreadable output); the other fields are then unknown.
  error?: string;
}

export type ClusterState =
  | 'serving'
  | 'loading'
  | 'not_serving'
  | 'stopped'
  | 'other_mac_away'
  | 'not_paired'
  | 'unknown'
  | 'pairing_unreadable';

// Actions that change a pair. Start, stop and restart of a pair use the ordinary `start` (with no
// models), `stop` and `restart` actions: on a paired Mac they control the pair.
export type ClusterAction =
  // `darkbloom cluster leave --yes`: stop this Mac's part and forget its pairing.
  { action: 'cluster_leave' };

// The guided setup, run by the desktop API as `darkbloom cluster --app-console` (kind `setup`) or
// `darkbloom cluster local --app-console [<model>] [--bind <address>]` (kind `local`). The child's
// screen arrives as events; its questions are answered by the app. One session at a time.
export type ClusterSessionKind = 'setup' | 'local';

export interface ClusterSessionStart {
  kind: ClusterSessionKind;
  // `local` only: choose this model without the list, and where the leader's API listens.
  model?: string;
  bind?: string;
}

// One event of the setup's screen, in order. A transcript replays them all.
export type ClusterConsoleEvent =
  // The setup's opening: its name and the steps ahead.
  | { type: 'banner'; title: string; subtitle: string }
  | { type: 'heading'; text: string }
  // One line. `stressed` is the part a terminal shows in bold (lead + stressed + tail = text).
  | {
      type: 'say';
      text: string;
      stressed?: { lead: string; stressed: string; tail: string };
    }
  // Work still running (one row per Mac); replaced by the next `working`, ended by `settle` or
  // by the next said line.
  | { type: 'working'; rows: string[] }
  | { type: 'settle' }
  // A copy's or download's live report, replaced in place by the next one.
  | { type: 'progress'; text: string }
  // The setup's outcome block: ✓ (ok) or ✗ with what serves, or why nothing does.
  | { type: 'result'; ok: boolean; title: string; lines: string[] }
  // A step the app can't do (it needs Terminal, such as sudo where macOS shows no approval).
  | { type: 'needs_terminal'; text: string };

// What the setup is waiting for. `choose`: one of `options` (the arrow-key list in Terminal);
// `selected` is the default. `key`: the setup waits and accepts one of `keys` (such as `q` to
// leave or `r` to retry) while it works; it times out by itself.
export type ClusterQuestion =
  | {
      id: string;
      type: 'choose';
      // Each option's rows: the first is its title, the rest its detail lines.
      options: string[][];
      selected: number;
    }
  | { id: string; type: 'key'; keys: { key: string; label: string }[] };

export interface ClusterSession {
  id: string;
  kind: ClusterSessionKind;
  state: 'running' | 'succeeded' | 'failed' | 'cancelled';
  started_at: number;
  finished_at?: number;
  events: ClusterConsoleEvent[];
  // Set while the setup waits for an answer.
  question: ClusterQuestion | null;
  exit_code?: number;
  // Why the session could not start or ended early (not the setup's own result block).
  error?: string;
}

// `choice` answers a `choose`; `key` answers a `key` question. `cancel` leaves the setup the way
// `q` does in Terminal.
export type ClusterSessionAnswer =
  { question: string; choice: number } | { question: string; key: string } | { cancel: true };
