// Darkbloom Sandbox: approved GitHub Actions jobs in Linux and macOS VMs, run by the separately
// installed add-on `DarkbloomSandbox.app` (docs/provider/sandboxes.md).

// `GET /control/v1/sandbox`: the add-on's `status --json` (schema 1) as `darkbloom sandbox status
// --json` prints it. Without the add-on, a `not_installed` document. Decoded leniently: only
// `schema` and `state` are required (docs/provider/cli-reference.md#add-on-commands).
export interface SandboxStatus {
  schema: number;
  installed?: boolean;
  version?: string | null;
  host_id?: string | null;
  state: SandboxState | string;
  detail?: string | null;
  slots?: {
    linux?: { total: number; free: number };
    macos?: { total: number; free: number };
  } | null;
  jobs_running?: number | null;
  images?: {
    platform: 'linux' | 'macos' | string;
    state: 'installed' | 'downloading' | 'missing' | string;
    progress: number | null;
  }[];
  accepting?: boolean | null;
  // Unix seconds (the desktop API normalizes milliseconds and ISO 8601).
  last_update_check?: number | null;
  console_url?: string | null;
  // Present only on add-on releases with work disks (1.2.0 and later).
  disks?: SandboxDisk[] | null;
  // Set by the desktop API when the status could not be read at all.
  error?: string;
}

export type SandboxState =
  | 'not_installed'
  | 'waiting_for_approval'
  | 'waitlisted'
  | 'enrolling'
  | 'downloading_images'
  | 'ready'
  | 'running'
  | 'paused'
  | 'updating'
  | 'stopped'
  | 'error';

export interface SandboxDisk {
  path: string;
  root_volume?: boolean;
  state: string;
  detail?: string | null;
  free_bytes?: number | null;
  slots?: { linux?: { total: number }; macos?: { total: number } } | null;
}

// `GET /control/v1/sandbox-logs`: the last lines of `~/DarkbloomSandbox/agent/agent.log`
// (`darkbloom sandbox logs -n 200`). Read only on demand.
export interface SandboxLogs {
  lines: string[];
  observed_at: number;
  error?: string;
}

export type SandboxAction =
  // `darkbloom sandbox pause` / `resume`.
  | { action: 'sandbox_pause' | 'sandbox_resume' }
  // `darkbloom sandbox uninstall --yes`: running jobs end unpaid.
  | { action: 'sandbox_uninstall' }
  // `darkbloom sandbox setup --yes --no-browser [--linux-slots n] [--macos-slots n] [--disk p]…
  // [--wait-ready]`. A disk is a full path, or `~` to keep this Mac's internal disk as well. Its
  // operation reports `sandbox_setup` (below) while it runs.
  | {
      action: 'sandbox_setup';
      linux_slots?: number;
      macos_slots?: number;
      disks?: string[];
      wait_ready?: boolean;
    };

// Reported on a running or finished `sandbox_setup` operation (`Operation.sandbox_setup`).
export interface SandboxSetupProgress {
  // The installer's stage (`checking_mac`, `verifying_release`, `installing`,
  // `waiting_for_approval`, `enrolled`, `starting`, `downloading_images`, `ready`, …).
  stage?: string;
  step?: number;
  steps?: number;
  message?: string;
  // The one browser approval: open the URL and enter the code.
  approval?: {
    user_code: string;
    verification_uri: string;
    verification_uri_complete?: string | null;
  } | null;
  // The account waits on the Darkbloom Sandbox waitlist; `background`: the Mac keeps waiting
  // and enrolls by itself once approved, so the app can be closed.
  waitlisted?: boolean;
  background?: boolean;
  // Image download progress, 0 to 1, with `wait_ready`.
  progress?: number | null;
  // The CLI's exit status once the setup ended without success: the installer's `2` (this Mac
  // can't host Darkbloom Sandbox as it is), `3` (not enrolled) or `4` (a job is running, so
  // nothing changed), `130` (stopped), else `1`. Absent while it runs; without it the app reads
  // the CLI's own last line (docs/provider/cli-reference.md#installer-progress-events).
  exit_status?: number | null;
}

// Jobs at a time the CLI takes (`--linux-slots`, `--macos-slots`); both 0 is refused.
export const sandboxSlotLimits = { linux: 16, macos: 2 } as const;
