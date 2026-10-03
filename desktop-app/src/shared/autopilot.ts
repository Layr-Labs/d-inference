// Mirrors `darkbloom start --autopilot --model … [--local-endpoint]` followed by
// `darkbloom autopilot pin …`. `models` are the startup models: the runtime downloads and
// verifies them, and once cached they join Autopilot's approved inventory. `pinned` must be a
// subset of `models`; a pinned model is protected from automatic unloading.
export interface AutopilotAction {
  action: 'autopilot';
  models: string[];
  pinned: string[];
  endpoint?: boolean;
}

// One action per `darkbloom autopilot` subcommand:
// - `autopilot_pin` / `autopilot_unpin` → `autopilot pin|unpin <models>`; pins must already be
//   in the pool (`AutopilotStatus.selected`).
// - `autopilot_pause` / `autopilot_resume` → `autopilot pause|resume`.
// - `autopilot_disable` → `autopilot disable`; loaded models stay as they are.
// - `autopilot_models` → `autopilot models`: re-inventories the downloaded models into the pool
//   through the runtime's safe drain and restart. Downloading alone never adds to the pool.
export type AutopilotPolicyAction =
  | { action: 'autopilot_pin' | 'autopilot_unpin'; models: string[] }
  | { action: 'autopilot_pause' | 'autopilot_resume' | 'autopilot_disable' | 'autopilot_models' };

// The configured enrollment from `darkbloom autopilot status --json`, reported in every
// snapshot from a runtime that supports the actions above; its absence means the runtime
// can't run Autopilot. `selected` is the pool and `phase` the live daemon phase, absent while
// the daemon isn't reporting.
export interface AutopilotStatus {
  enabled: boolean;
  paused: boolean;
  selected: string[];
  pinned: string[];
  phase?:
    | 'off'
    | 'waiting'
    | 'waiting_inventory'
    | 'shadow'
    | 'active'
    | 'paused'
    | 'transitioning'
    | 'recovering';
}
