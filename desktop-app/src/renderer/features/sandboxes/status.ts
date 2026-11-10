import type { SandboxDisk, SandboxStatus } from '../../../shared/sandbox';

// How the page reads the add-on's `status --json`, after the CLI's own `darkbloom sandbox status`
// (provider-swift/Sources/darkbloom/Sandbox/SandboxStatusView.swift): the same headline, levels
// and lines, with the app's buttons where the CLI names a command.

export type Tone = 'pass' | 'warn' | 'fail' | 'info';

export const jobs = (count: number) => (count === 1 ? '1 job' : `${count} jobs`);

// Rounded down, as the CLI does: an image is never shown done before it is.
export const percent = (fraction: number) =>
  `${Math.floor(Math.min(Math.max(fraction, 0), 1) * 100)}%`;

// `linux_arm64` reads as Linux, `macos_arm64` as macOS.
export function platformName(platform: string) {
  const lowered = platform.toLowerCase();
  if (lowered.startsWith('linux')) return 'Linux';
  if (lowered.startsWith('macos')) return 'macOS';
  return platform;
}

// `installed: false` and `not_installed` both read as not set up.
export const isInstalled = (status: SandboxStatus | undefined) =>
  !!status && status.installed !== false && status.state !== 'not_installed';

export const jobsRunning = (status: SandboxStatus) =>
  Math.max(0, Math.floor(status.jobs_running ?? 0));

const sentence = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);

// The state in a few words and how it reads: green, amber, red or plain.
export function headline(status: SandboxStatus): { text: string; tone: Tone } {
  const running = jobsRunning(status);
  switch (status.state) {
    case 'not_installed':
      return { text: 'Not set up', tone: 'info' };
    case 'waiting_for_approval':
      return { text: 'Waiting for approval', tone: 'warn' };
    case 'waitlisted':
      return { text: 'On the waitlist', tone: 'warn' };
    case 'enrolling':
      return { text: 'Enrolling', tone: 'warn' };
    case 'downloading_images': {
      const image = status.images?.find((item) => item.state === 'downloading');
      const detail =
        image && image.progress != null
          ? ` · ${platformName(image.platform)} ${percent(image.progress)}`
          : '';
      return { text: `Downloading images${detail}`, tone: 'warn' };
    }
    case 'ready':
      return { text: running > 0 ? `Running ${jobs(running)}` : 'Ready', tone: 'pass' };
    case 'running':
      return { text: `Running ${jobs(running)}`, tone: 'pass' };
    case 'paused':
      return { text: 'Paused', tone: 'warn' };
    case 'updating':
      return { text: 'Updating', tone: 'warn' };
    case 'stopped':
      return { text: 'Stopped', tone: 'fail' };
    case 'error':
      return { text: 'Error', tone: 'fail' };
    default:
      return { text: sentence(String(status.state).replaceAll('_', ' ')), tone: 'info' };
  }
}

// What the state means for this Mac and its inference, with the app's own controls.
export function meaning(status: SandboxStatus): string {
  const running = jobsRunning(status);
  switch (status.state) {
    case 'not_installed':
      return 'Not set up on this Mac.';
    case 'waiting_for_approval':
      return 'Approve this Mac in your browser, signed in to your Darkbloom account. Continue setup to see the link and code again.';
    case 'waitlisted':
      return 'Darkbloom has not approved your account to host sandboxes yet. This Mac enrolls as soon as it does.';
    case 'enrolling':
      return 'Finishing enrollment.';
    case 'downloading_images':
      return 'Jobs start once an image is installed.';
    case 'ready':
      if (running === 0)
        return status.accepting === false
          ? 'Not taking jobs right now.'
          : 'Waiting for jobs. Inference runs as usual until a job starts.';
      return 'Inference is paused while jobs run, and resumes after the last one ends.';
    case 'running':
      return 'Inference is paused while jobs run, and resumes after the last one ends.';
    case 'paused':
      return running > 0
        ? `${jobs(running)} still running; ${running === 1 ? 'it finishes' : 'they finish'} normally. No new jobs until you resume.`
        : 'No new jobs until you resume. Inference runs as usual.';
    case 'updating':
      return 'Installing a new version of the add-on between jobs.';
    case 'stopped':
      return 'The agent is not running, so this Mac gets no jobs. Repair to start it.';
    case 'error':
      return 'See the logs for details.';
    default:
      return 'Your add-on is newer than this Darkbloom CLI. Update the CLI to match it.';
  }
}

// The line under the headline. While jobs can run, what the state means for inference;
// otherwise the add-on's own `detail` is the most specific (a refusal, the approval, disk space).
export function explanation(status: SandboxStatus): string {
  const detail = status.detail?.trim();
  switch (status.state) {
    case 'running':
    case 'paused':
    case 'stopped':
      return meaning(status);
    case 'ready':
      if (status.accepting !== false || jobsRunning(status) > 0) return meaning(status);
      return detail || meaning(status);
    default:
      return detail || meaning(status);
  }
}

// The control that moves this state along, as the CLI's next step.
export type NextStep = 'resume' | 'continue' | 'repair' | 'pause';
export function nextStep(status: SandboxStatus): NextStep {
  switch (status.state) {
    case 'paused':
      return 'resume';
    case 'waiting_for_approval':
    case 'waitlisted':
    case 'enrolling':
      return 'continue';
    case 'stopped':
    case 'error':
      return 'repair';
    default:
      return 'pause';
  }
}

// Free slots mean something only while the agent reports.
export const reportsSlots = (status: SandboxStatus) =>
  ['ready', 'running', 'paused', 'updating'].includes(status.state);

// The states where `setup` with new counts reinstalls the add-on; elsewhere it continues or
// repairs the setup instead.
export const changesSlots = (status: SandboxStatus) =>
  ['ready', 'running', 'paused', 'downloading_images', 'updating'].includes(status.state);

export interface PlatformSlots {
  platform: 'Linux' | 'macOS';
  total: number;
  free: number;
}

// Each platform with slots; a platform without any is left out, as the add-on does.
export function slots(status: SandboxStatus): PlatformSlots[] {
  return (
    [
      ['Linux', status.slots?.linux],
      ['macOS', status.slots?.macos],
    ] as const
  ).flatMap(([platform, value]) => {
    const total = Math.max(0, Math.floor(value?.total ?? 0));
    if (total === 0) return [];
    const free = Math.min(Math.max(0, Math.floor(value?.free ?? 0)), total);
    return [{ platform, total, free }];
  });
}

export function imageState(image: NonNullable<SandboxStatus['images']>[number]) {
  if (image.state === 'downloading')
    return image.progress != null ? `Downloading ${percent(image.progress)}` : 'Downloading';
  if (image.state === 'installed') return 'Installed';
  if (image.state === 'missing') return 'Missing';
  return sentence(String(image.state).replaceAll('_', ' '));
}

// Work disks are worth a line only with an external drive or more than one disk.
export function shownDisks(status: SandboxStatus): SandboxDisk[] {
  const disks = (status.disks ?? []).filter((disk) => disk.path && disk.state);
  return disks.length > 1 || disks.some((disk) => !disk.root_volume) ? disks : [];
}

export const gib = (bytes: number) => `${Math.floor(Math.max(0, bytes) / 2 ** 30)} GiB`;

export function diskSlots(disk: SandboxDisk) {
  return (
    [
      ['Linux', disk.slots?.linux?.total ?? 0],
      ['macOS', disk.slots?.macos?.total ?? 0],
    ] as const
  )
    .filter(([, total]) => total > 0)
    .map(([platform, total]) => `${platform} ${total}`)
    .join(', ');
}

// How long ago a Unix time was, in the app's short form.
export function ago(at: number, now = Date.now() / 1000) {
  const seconds = Math.max(0, now - at);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86_400)}d ago`;
}

export function updateCheck(status: SandboxStatus, now?: number) {
  return status.last_update_check
    ? `Updates automatic, last checked ${ago(status.last_update_check, now)}`
    : 'Updates automatic, not checked yet';
}
