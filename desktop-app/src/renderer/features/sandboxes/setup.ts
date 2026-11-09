import type { Operation } from '../../../shared/contracts';
import { sandboxSlotLimits, type SandboxAction } from '../../../shared/sandbox';
import { percent } from './status';

// The installer's stages in order, in the CLI's words (`SandboxInstallerEvent.title`).
export const setupStages = [
  { id: 'checking_mac', title: 'Checking this Mac' },
  { id: 'verifying_release', title: 'Verifying release' },
  { id: 'installing', title: 'Installing' },
  { id: 'waiting_for_approval', title: 'Waiting for approval' },
  { id: 'enrolled', title: 'Enrolled' },
  { id: 'starting', title: 'Starting' },
  { id: 'downloading_images', title: 'Downloading images' },
  { id: 'ready', title: 'Ready' },
] as const;

const approvalStage = setupStages.findIndex((stage) => stage.id === 'waiting_for_approval');

export type StepState = 'done' | 'active' | 'failed' | 'stopped' | 'pending';
export interface SetupStep {
  id: string;
  title: string;
  state: StepState;
  // The download's progress (0 to 1), shown on the running step.
  progress?: number;
  // Why the failed step failed, in the installer's words.
  detail?: string;
}

// The newest `sandbox_setup` operation; the runtime lists operations newest first.
export const latestSetup = (operations: Operation[]) =>
  operations.find((operation) => operation.action === 'sandbox_setup');

// An unknown stage keeps the installer's words.
export function stageTitle(stage: string | undefined, message?: string) {
  const known = setupStages.find((item) => item.id === stage);
  if (known) return known.title;
  if (message?.trim()) return message.trim().split('\n')[0];
  if (!stage) return 'Setup';
  const words = stage.replaceAll('_', ' ');
  return words.charAt(0).toUpperCase() + words.slice(1);
}

// Where the setup is: the reported stage, else its step number. Before the installer reports
// anything the CLI is checking this Mac itself, which is the first stage too.
function currentIndex(operation: Operation) {
  const progress = operation.sandbox_setup;
  const known = setupStages.findIndex((stage) => stage.id === progress?.stage);
  if (known >= 0) return known;
  if (progress?.step && progress.step >= 1)
    return Math.min(Math.floor(progress.step), setupStages.length) - 1;
  return 0;
}

// Whether the installer reported a stage at all. A setup that stops before it runs (the
// waitlist, the CLI's own checks, the download) has no steps to show.
export const reportedStage = (operation: Operation) =>
  !!operation.sandbox_setup?.stage || !!operation.sandbox_setup?.step;

export function setupSteps(operation: Operation): SetupStep[] {
  const progress = operation.sandbox_setup ?? {};
  const running = operation.state === 'running';
  if (!running && !reportedStage(operation)) return [];
  const current = currentIndex(operation);
  const unknown = !!progress.stage && !setupStages.some((stage) => stage.id === progress.stage);
  return setupStages.map((stage, index): SetupStep => {
    const title = index === current && unknown ? stageTitle(progress.stage) : stage.title;
    if (operation.state === 'succeeded' || index < current)
      return { id: stage.id, title: stage.title, state: 'done' };
    if (index > current) return { id: stage.id, title, state: 'pending' };
    if (running) {
      if (progress.waitlisted && stage.id === 'waiting_for_approval')
        return {
          id: stage.id,
          title: 'Waiting for Darkbloom to approve your account',
          state: 'active',
        };
      if (stage.id === 'downloading_images' && progress.progress != null)
        return {
          id: stage.id,
          title: `${title} ${percent(progress.progress)}`,
          state: 'active',
          progress: Math.min(Math.max(progress.progress, 0), 1),
        };
      return { id: stage.id, title, state: 'active' };
    }
    if (operation.state === 'failed')
      return {
        id: stage.id,
        title,
        state: 'failed',
        detail: progress.message?.trim() || undefined,
      };
    return { id: stage.id, title, state: 'stopped' };
  });
}

const reachedApproval = (operation: Operation) =>
  reportedStage(operation) && currentIndex(operation) >= approvalStage;

// The one browser approval, while the setup waits for it.
export function pendingApproval(operation: Operation) {
  const progress = operation.sandbox_setup;
  if (operation.state !== 'running' || !progress?.approval || progress.waitlisted) return undefined;
  if (currentIndex(operation) > approvalStage) return undefined;
  const { user_code, verification_uri, verification_uri_complete } = progress.approval;
  if (!verification_uri && !verification_uri_complete) return undefined;
  return {
    code: user_code,
    url: verification_uri_complete || verification_uri,
    // The page fills in the code itself only from the complete link.
    codeFilled: !!verification_uri_complete,
  };
}

// The last lines the CLI printed, newest last.
export function outputLines(operation: Operation): string[] {
  const lines = operation.lines ?? operation.message.split('\n');
  return lines.map((line) => line.replace(/\s+$/, '')).filter((line) => line.trim());
}

// The CLI's own sentence for each installer exit status (`SandboxSetupCommand.advice`).
const advice: [RegExp, number][] = [
  [/cannot host Darkbloom Sandbox as it is/, 2],
  [/was not enrolled/, 3],
  [/A job is running on this Mac, so the installer changed nothing/, 4],
  [/^Setup stopped\./, 130],
];

export function exitStatus(operation: Operation): number | undefined {
  const reported = operation.sandbox_setup?.exit_status;
  if (typeof reported === 'number') return reported;
  if (operation.state === 'cancelled') return 130;
  if (operation.state !== 'failed') return undefined;
  const lines = outputLines(operation);
  for (let index = lines.length - 1; index >= 0; index--) {
    const match = advice.find(([pattern]) => pattern.test(lines[index].trim()));
    if (match) return match[1];
  }
  return 1;
}

export interface SetupOutcome {
  title: string;
  detail?: string;
}

const isAdvice = (line: string) =>
  advice.some(([pattern]) => pattern.test(line.trim())) || /^Setup did not finish\./.test(line);

// What an ended setup means, by the installer's exit status. Undefined while it runs and after
// it succeeds.
export function setupOutcome(operation: Operation): SetupOutcome | undefined {
  if (operation.state === 'running' || operation.state === 'succeeded') return undefined;
  const progress = operation.sandbox_setup ?? {};
  const why = progress.stage ? progress.message?.trim() || undefined : undefined;
  if (operation.state === 'interrupted')
    return { title: 'Setup was interrupted.', detail: operation.message.trim() || undefined };
  switch (exitStatus(operation)) {
    case 2:
      return { title: 'This Mac can’t host Darkbloom Sandbox as it is.', detail: why };
    case 3:
      return {
        title: 'This Mac was not enrolled.',
        detail:
          'The code was denied or expired, or the waitlist request ended. Set up again for a new code.',
      };
    case 4:
      return {
        title: 'A job is running, so nothing changed.',
        detail:
          'The installer refuses rather than waits. Try again when the job finishes; Pause keeps new jobs from starting.',
      };
    case 130:
      // Only a setup that reached the approval leaves an enrollment waiting.
      return {
        title: 'Setup stopped.',
        detail: !reachedApproval(operation)
          ? undefined
          : progress.background
            ? 'This Mac keeps waiting for approval in the background, also across restarts, and enrolls by itself once approved.'
            : 'An enrollment waiting for approval goes on. Set up again to follow it.',
      };
    default: {
      const last = outputLines(operation)
        .filter((line) => !isAdvice(line))
        .at(-1)
        ?.trim();
      return {
        title: 'Setup did not finish.',
        detail: why ?? last ?? 'It is safe to set up again.',
      };
    }
  }
}

// The setup form's choices, as typed.
export interface SetupChoice {
  automatic: boolean;
  linux: string;
  macos: string;
  disk: string;
  waitReady: boolean;
}

const whole = (text: string) => (/^\s*\d{1,3}\s*$/.test(text) ? Number(text) : undefined);

export interface SlotCounts {
  counts?: { linux_slots: number; macos_slots: number };
  error?: string;
}

// Jobs at a time: Linux 0 to 16, macOS 0 to 2, never both 0 (the CLI refuses it).
export function slotCounts(linux: string, macos: string): SlotCounts {
  const linuxSlots = whole(linux);
  const macosSlots = whole(macos);
  if (linuxSlots === undefined || linuxSlots > sandboxSlotLimits.linux)
    return { error: `Linux jobs: 0 to ${sandboxSlotLimits.linux}.` };
  if (macosSlots === undefined || macosSlots > sandboxSlotLimits.macos)
    return { error: `macOS jobs: 0 to ${sandboxSlotLimits.macos}.` };
  if (linuxSlots === 0 && macosSlots === 0) return { error: 'Choose at least one job.' };
  return { counts: { linux_slots: linuxSlots, macos_slots: macosSlots } };
}

// A work disk is an absolute path that stays one argument, such as /Volumes/FastSSD: the runtime
// takes no `~`, `..` or control and format characters. The CLI checks the drive itself (APFS,
// ownership on) before it installs anything.
export function workDisk(text: string): { path?: string; error?: string } {
  const path = text.trim();
  if (!path) return {};
  if (path.length > 1024 || /[\p{Cc}\p{Cf}]/u.test(path))
    return { error: 'Enter the drive’s path, such as /Volumes/FastSSD.' };
  if (!path.startsWith('/') || path.split('/').includes('..'))
    return { error: 'Enter the drive’s full path, such as /Volumes/FastSSD.' };
  return { path };
}

export function setupRequest(choice: SetupChoice): {
  action?: Extract<SandboxAction, { action: 'sandbox_setup' }>;
  slotsError?: string;
  diskError?: string;
} {
  const slots: SlotCounts = choice.automatic ? {} : slotCounts(choice.linux, choice.macos);
  const disk = workDisk(choice.disk);
  if (slots.error || disk.error) return { slotsError: slots.error, diskError: disk.error };
  return {
    action: {
      action: 'sandbox_setup',
      ...slots.counts,
      ...(disk.path ? { disks: [disk.path] } : {}),
      ...(choice.waitReady ? { wait_ready: true } : {}),
    },
  };
}
