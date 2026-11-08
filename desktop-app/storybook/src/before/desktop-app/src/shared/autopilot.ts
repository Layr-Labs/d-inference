// Mirrors `darkbloom start --autopilot --model … [--local-endpoint]` followed by
// `darkbloom autopilot pin …`. `downloads` are explicitly chosen downloads, completed before
// the CLI verifies cached inventory and starts `models`. `pinned` must be a
// subset of `models`; a pinned model is protected from automatic unloading.
export interface AutopilotAction {
  action: 'autopilot';
  models: string[];
  downloads?: string[];
  pinned: string[];
  endpoint?: boolean;
}

// One action per `darkbloom autopilot` subcommand:
// - `autopilot_pin` / `autopilot_unpin` → `autopilot pin|unpin <models>`; pins must already be
//   in the pool (`AutopilotStatus.selected`).
// - `autopilot_pause` / `autopilot_resume` → `autopilot pause|resume`.
// - `autopilot_disable` → `autopilot disable`; loaded models stay as they are.
// - `autopilot_models` → noninteractive `start --autopilot --model <saved startup models>`:
//   re-inventories cached models through the same safe drain/restart used by `autopilot models`.
export type AutopilotPolicyAction =
  | { action: 'autopilot_pin' | 'autopilot_unpin'; models: string[] }
  | { action: 'autopilot_pause' | 'autopilot_resume' | 'autopilot_disable' | 'autopilot_models' };

// The configured enrollment from `darkbloom autopilot status --json`, reported in every
// snapshot from a runtime that supports the actions above; its absence means the runtime
// can't run Autopilot. `selected` is the pool and `phase` the live daemon phase, absent while
// the daemon isn't reporting.
export interface AutopilotStatus {
  configured?: boolean;
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
