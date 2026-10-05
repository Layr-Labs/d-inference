import type { AutopilotAction, AutopilotPolicyAction, AutopilotStatus } from './autopilot';
import type { Eligibility, WaitlistAction } from './eligibility';
import type { HardwareSample } from './hardware';
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
  | 'updates';
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
}
export interface NativeModel {
  id: string;
  display_name: string;
  size_gb: number;
  memory_gb?: number;
  downloaded: boolean;
  serving: boolean;
  loaded: boolean;
  eligible: boolean;
  reason?: string;
  description?: string;
  context_length?: number;
  family?: string;
  quantization?: string;
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
  account?: { signed_in: boolean; expires_at?: number; legacy_data?: boolean };
  state: 'stopped' | 'starting' | 'running' | 'draining' | 'stale';
  readiness: string;
  machine: Machine;
  models: NativeModel[];
  operations: Operation[];
  memory: { total_gb: number; active_gb?: number; cache_gb?: number; free_for_load_gb?: number };
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
  mode: string;
  temperature?: number;
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
  | { action: 'start' | 'switch'; models: string[]; local?: boolean; endpoint?: boolean }
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
  | AutopilotPolicyAction;
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
  | 'hardware';
export interface DesktopStatus {
  state: 'connecting' | 'ready' | 'missing' | 'incompatible' | 'error' | 'installing';
  message?: string;
}
export interface GUIUpdate {
  state: 'idle' | 'checking' | 'available' | 'downloading' | 'ready' | 'error' | 'unconfigured';
  version?: string;
  message?: string;
}
export interface DesktopAPI {
  read<T>(resource: Resource): Promise<T>;
  act(action: Action): Promise<Operation>;
  status(): Promise<DesktopStatus>;
  install(): Promise<void>;
  openExternal(
    target:
      'console' | 'docs' | 'community' | 'github' | 'slack' | 'x' | 'terms' | 'privacy' | 'link',
  ): Promise<void>;
  copy(text: string): Promise<void>;
  updateStatus(): Promise<GUIUpdate>;
  checkUpdate(): Promise<GUIUpdate>;
  applyUpdate(): Promise<void>;
  onState(callback: (state: Snapshot) => void): () => void;
  onStatus(callback: (status: DesktopStatus) => void): () => void;
  onNavigate(callback: (route: Route) => void): () => void;
  // Streams 1 Hz samples while subscribed; read('hardware') returns HardwareLoad.
  onHardware(callback: (sample: HardwareSample) => void): () => void;
}
declare global {
  interface Window {
    darkbloom?: DesktopAPI;
  }
}
