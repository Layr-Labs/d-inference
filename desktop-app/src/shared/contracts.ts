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
  state: 'stopped' | 'starting' | 'running' | 'draining' | 'stale';
  readiness: string;
  machine: Machine;
  models: NativeModel[];
  operations: Operation[];
  memory: { total_gb: number; active_gb?: number; cache_gb?: number; free_for_load_gb?: number };
  activity: {
    requests?: string;
    tokens?: string;
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
}
export interface ActivitySample {
  at: number;
  requests: number;
  tokens: number;
}
export interface CloudData {
  linked: boolean;
  account_id?: string;
  observed_at: number;
  lifetime_micro_usd?: string;
  week_micro_usd?: string;
  balance_micro_usd?: string;
  machines: Machine[];
  local_earnings_micro_usd?: string;
  error?: string;
}
export interface NetworkData {
  total_tokens?: string;
  total_requests?: string;
  total_macs?: number;
  error?: string;
}
export interface CoolingData {
  supported: boolean;
  mode: string;
  temperature?: number;
  fans: { name: string; rpm: number; max_rpm: number }[];
  error?: string;
}
export interface ReleaseData {
  version?: string;
  published_at?: string;
  notes?: string;
  url?: string;
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
  | { action: 'stop' | 'restart' | 'update' | 'diagnose' | 'link' | 'unlink' }
  | { action: 'download' | 'remove'; model: string }
  | { action: 'cancel'; operation: string }
  | {
      action: 'settings';
      revision: string;
      name: string;
      idle_minutes: number;
      auto_update: boolean;
      schedule?: Schedule;
      startup_preload?: boolean;
    }
  | { action: 'cooling'; enabled: boolean; speed?: number; temperature?: number };
export type Resource =
  | 'state'
  | 'cloud'
  | 'network'
  | 'cooling'
  | 'release'
  | 'leaderboard'
  | 'endpoint-key'
  | 'insights-week'
  | 'insights-month';
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
    target: 'console' | 'docs' | 'community' | 'terms' | 'privacy' | 'link',
  ): Promise<void>;
  copy(text: string): Promise<void>;
  updateStatus(): Promise<GUIUpdate>;
  checkUpdate(): Promise<GUIUpdate>;
  applyUpdate(): Promise<void>;
  onState(callback: (state: Snapshot) => void): () => void;
  onStatus(callback: (status: DesktopStatus) => void): () => void;
  onNavigate(callback: (route: Route) => void): () => void;
}
declare global {
  interface Window {
    darkbloom?: DesktopAPI;
  }
}
