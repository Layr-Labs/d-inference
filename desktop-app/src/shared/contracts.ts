import type { AutopilotAction, AutopilotPolicyAction, AutopilotStatus } from './autopilot';
import type { Eligibility, WaitlistAction } from './eligibility';
import type { HardwareSample } from './hardware';
import type { SystemInfo } from './macos';
import type { ChatAPI } from './chat';
import type {
  ClusterAction,
  ClusterSession,
  ClusterSessionAnswer,
  ClusterSessionStart,
} from './cluster';
import type { LocalServing, LocalServingAction } from './localServing';
import type { SandboxAction, SandboxSetupProgress } from './sandbox';
import type { WaitlistJoinAction } from './waitlists';
export type { HardwareLoad, HardwareSample, HardwareTopology } from './hardware';
export const protocolVersion = 1;
export type Route =
  | 'home'
  | 'machines'
  | 'models'
  | 'cooling'
  | 'analysis'
  | 'earnings'
  | 'settings'
  | 'studio'
  | 'leaderboard'
  | 'updates'
  | 'chat'
  | 'cluster'
  | 'sandboxes'
  | 'waitlists';
export interface Operation {
  id: string;
  action: Action['action'];
  state: 'running' | 'succeeded' | 'failed' | 'cancelled' | 'interrupted';
  started_at: number;
  finished_at?: number;
  message: string;
  cancellable: boolean;
  // Reported by runtimes that attribute a download to its model, with progress from 0 to 1.
  model?: string;
  progress?: number;
  // The last lines a long CLI action printed (sanitized, newest last), for actions whose output
  // the person needs while they run, such as `sandbox_setup`. Absent from older runtimes.
  lines?: string[];
  // A `sandbox_setup` operation's installer stage and its one browser approval.
  sandbox_setup?: SandboxSetupProgress;
}
export interface NativeModel {
  id: string;
  display_name: string;
  size_gb: number;
  memory_gb?: number | null;
  downloaded: boolean;
  serving: boolean;
  loaded: boolean;
  eligible: boolean;
  reason?: string | null;
  // Listed by the Darkbloom catalog. Only these can be served to the network or enrolled in
  // Autopilot; a model found only on disk runs with Only me. Absent from older runtimes.
  network?: boolean;
  // What this Mac's live coordinator registration carries for the model: `routable` in its
  // models (the network sends it requests), `autopilot` in its Autopilot inventory only, `none`
  // in neither. Null or absent when not connected or on an older runtime.
  registration?: 'routable' | 'autopilot' | 'none' | null;
  description?: string | null;
  context_length?: number | null;
  family?: string | null;
  quantization?: string | null;
}
export interface Machine {
  id: string;
  name: string;
  chip: string;
  memory_gb: number;
  status: string;
  observed_at?: number;
  version?: string;
  models: string[];
  earnings_micro_usd?: string;
  // Settled, including base rewards: all time and rolling 24 hours.
  lifetime_micro_usd?: string;
  day_micro_usd?: string;
  requests_24h?: number;
  tokens_24h?: MachineTokens;
  // Output tokens for the 24 local clock hours ending with the hour containing observed_at,
  // oldest first; null marks an hour with no observation, which is not zero.
  hourly_tokens?: (number | null)[];
  online_since?: number;
  last_paid_at?: number;
}
export interface MachineTokens {
  // Uncached prompt tokens; cached_input counts prompt tokens served from the prefix cache.
  input?: number;
  cached_input?: number;
  output: number;
}
export interface Schedule {
  enabled: boolean;
  windows: { days: string[]; start: string; end: string }[];
}
export interface Snapshot {
  protocol: number;
  version: string;
  observed_at: number;
  installation_id: string;
  linked: boolean;
  account_revision?: string;
  resource_revision?: string;
  capabilities?: string[];
  // The two-Mac pair this Mac is in: its model (the name, else the ID; null until the pair has
  // one), its state from this Mac's own view, and whether this Mac leads it, so chooses its model
  // (null when not known). Null when this Mac isn't paired; absent from older runtimes, and
  // `state` and `leads` from runtimes before they were reported. Start serving starts the pair.
  pair?: {
    model: string | null;
    state?: 'serving' | 'started' | 'not_running' | 'stopped' | 'unreadable';
    leads?: boolean | null;
  } | null;
  account?: {
    signed_in: boolean;
    email?: string | null;
    expires_at?: number;
    legacy_data?: boolean;
  };
  state: 'stopped' | 'starting' | 'running' | 'draining' | 'stale';
  readiness: string;
  /** Coordinator-reported connection status, distinct from its diagnostic event reason. */
  provider_status?: string | null;
  machine: Machine;
  models: NativeModel[];
  operations: Operation[];
  memory: {
    total_gb: number;
    active_gb?: number;
    cache_gb?: number;
    free_for_load_gb?: number;
    pin_budget_gb?: number;
    max_model_slots?: number;
  };
  activity: {
    requests?: string;
    tokens?: string;
    /** All prompt tokens, including cached input; output already includes reasoning. */
    prompt_tokens?: string | null;
    usage_gaps?: string | null;
    processed_tokens?: string | null;
    processed_input_tokens?: string | null;
    processed_output_tokens?: string | null;
    cached_input_tokens?: string | null;
    reasoning_tokens?: string | null;
    counted_requests?: string | null;
    pending_usage_requests?: string | null;
    usage_source?: 'local' | 'settled-history';
    usage_observed_at?: number;
    /** Settled earnings for this provider session only, when the server supplies them. */
    earnings_micro_usd?: string | null;
    started_at?: number;
    samples: ActivitySample[];
    sampled_at?: number;
    models?: { model: string; state: string; running: number; waiting: number }[] | null;
  };
  settings: {
    revision: string;
    name: string;
    auto_update: boolean;
    idle_minutes: number;
    cache_path: string;
    schedule?: Schedule;
    startup_preload?: boolean;
  };
  endpoint?: { base_url: string; authenticated: boolean; models: string[] };
  link?: { url: string; code: string; expires_at: number; state: string };
  catalog_error?: string;
  eligibility?: Eligibility;
  autopilot?: AutopilotStatus;
  // How this Mac serves and where your requests go (provider.toml `[local]`).
  local?: LocalServing;
}
export interface ActivitySample {
  at: number;
  requests: number;
  tokens: number;
  // Session-cumulative prompt tokens, split so the two never overlap: input_tokens counts only
  // uncached prompt tokens; cached_input_tokens counts those served from the prefix cache.
  input_tokens?: number;
  cached_input_tokens?: number;
}
export interface CloudData {
  linked: boolean;
  account_id?: string;
  observed_at: number;
  lifetime_micro_usd?: string;
  week_micro_usd?: string;
  /** False when the returned records cover only part of the requested week. */
  earnings_complete?: boolean;
  earnings_since?: number;
  settled_records?: string;
  balance_micro_usd?: string;
  machines: Machine[];
  local_earnings_micro_usd?: string;
  minimum_provider_version?: string;
  // This Mac's settled earnings including base rewards: all time, and the rolling past 24 hours.
  local_lifetime_micro_usd?: string;
  local_day_micro_usd?: string;
  error?: string;
}
// Request metadata only: history never carries prompt or response content.
export interface RequestRecord {
  id: string;
  started_at?: number;
  settled_at?: number;
  completed_at?: number;
  model: string;
  input_tokens: number;
  output_tokens: number;
  duration_ms?: number;
  outcome: 'completed' | 'cancelled' | 'failed' | 'settled';
  // Omitted until the request settles.
  earnings_micro_usd?: string;
}
export interface RequestHistory {
  observed_at: number;
  since?: number;
  records: RequestRecord[];
}
export interface NetworkData {
  model_earnings?: {
    window: '7d';
    as_of: string;
    models: { id: string; earnings_micro_usd: string }[];
  } | null;
  total_tokens?: string;
  total_requests?: string;
  // Prompt plus completion tokens in the past 24 hours; omitted by runtimes that do not relay it.
  last_24h_tokens?: string;
  total_macs?: number;
  provider_regions?: unknown;
  error?: string;
}
export interface CoolingData {
  supported: boolean;
  enabled?: boolean | null;
  observed_at?: number;
  mode: string;
  temperature?: number | null;
  fans: { name: string; rpm: number; max_rpm: number }[];
  control_available?: boolean;
  speed?: number;
  threshold?: number;
  error?: string;
}
export interface ReleaseData {
  version?: string;
  published_at?: string;
  notes?: string;
  url?: string;
  error?: string;
}
export interface ReleaseHistory {
  minimum_provider_version?: string;
  observed_at?: string;
  history: { version: string; published_at: string; notes: string; active: boolean }[];
  error?: string;
}
export interface Leader {
  rank: number;
  name: string;
  tokens: string;
  earnings_micro_usd?: string;
}
export type Action =
  // `local`: Only me (`--local`); `endpoint`: Both, me first (`--local-endpoint`); `network`:
  // the Darkbloom network with no local API (`--network`). Each is saved as `[local] mode`, which
  // later starts follow. `solo`: on a paired Mac, `start --solo` serves this Mac alone.
  | {
      action: 'start' | 'switch';
      models: string[];
      local?: boolean;
      endpoint?: boolean;
      network?: boolean;
      solo?: boolean;
    }
  | {
      action:
        | 'stop'
        | 'restart'
        | 'update'
        | 'diagnose'
        | 'link'
        | 'unlink'
        | 'account-signin'
        | 'account-signout';
    }
  | { action: 'download' | 'remove'; model: string }
  | { action: 'cancel'; operation: string }
  | {
      action: 'settings';
      revision: string;
      name: string;
      idle_minutes: number;
      auto_update: boolean;
      schedule?: Schedule;
    }
  | { action: 'cooling'; enabled: boolean; speed?: number; temperature?: number }
  | WaitlistAction
  | AutopilotAction
  | AutopilotPolicyAction
  | ClusterAction
  | SandboxAction
  | WaitlistJoinAction
  | LocalServingAction;
export type Resource =
  | 'state'
  | 'cloud'
  | 'network'
  | 'cooling'
  | 'release'
  | 'release-history'
  | 'leaderboard'
  | 'endpoint-key'
  | 'insights-week'
  | 'insights-month'
  | 'request-history'
  | 'hardware'
  | 'cluster'
  | 'sandbox'
  | 'sandbox-logs'
  | 'waitlists';
export interface DesktopStatus {
  state: 'connecting' | 'ready' | 'missing' | 'incompatible' | 'error' | 'installing';
  message?: string;
  // The last install failed; `message` names the step and the installer's reason.
  installFailed?: boolean;
}
export interface GUIUpdate {
  state: 'idle' | 'checking' | 'available' | 'downloading' | 'ready' | 'error' | 'unconfigured';
  version?: string;
  message?: string;
}
export interface DesktopAPI extends ChatAPI {
  read<T>(resource: Resource): Promise<T>;
  act(action: Action): Promise<Operation>;
  status(): Promise<DesktopStatus>;
  install(): Promise<void>;
  // Stops an in-progress install; the status then reports it as cancelled.
  cancelInstall(): Promise<void>;
  openExternal(
    target:
      'console' | 'docs' | 'community' | 'github' | 'slack' | 'x' | 'terms' | 'privacy' | 'link',
  ): Promise<void>;
  copy(text: string): Promise<void>;
  // This Mac's macOS version, read by the main process.
  system(): Promise<SystemInfo>;
  // Opens System Settings at Software Update; the URL is fixed in the main process.
  openSoftwareUpdate(): Promise<void>;
  updateStatus(): Promise<GUIUpdate>;
  checkUpdate(): Promise<GUIUpdate>;
  applyUpdate(): Promise<void>;
  onState(callback: (state: Snapshot) => void): () => void;
  onStatus(callback: (status: DesktopStatus) => void): () => void;
  onNavigate(callback: (route: Route) => void): () => void;
  // Streams 1 Hz samples while subscribed; read('hardware') returns HardwareLoad.
  onHardware(callback: (sample: HardwareSample) => void): () => void;
  // The guided cluster setup (`darkbloom cluster` with the app's screens). `clusterSession`
  // returns the current or last session (null when none ran since the API started).
  clusterSession(): Promise<ClusterSession | null>;
  startClusterSession(start: ClusterSessionStart): Promise<ClusterSession>;
  answerClusterSession(answer: ClusterSessionAnswer): Promise<ClusterSession>;
  // Streams the whole session on every change while subscribed.
  onClusterSession(callback: (session: ClusterSession) => void): () => void;
  // Opens a sandbox approval page from a running `sandbox_setup` operation; the main process
  // accepts only an https URL on a Darkbloom host.
  openApproval(url: string): Promise<void>;
}
declare global {
  interface Window {
    darkbloom?: DesktopAPI;
  }
}
