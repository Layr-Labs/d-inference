import { describe, expect, it } from 'vitest';
import type { SandboxStatus } from '../src/shared/sandbox';
import {
  explanation,
  headline,
  imageState,
  isInstalled,
  nextStep,
  percent,
  platformName,
  reportsSlots,
  shownDisks,
  slots,
  updateCheck,
} from '../src/renderer/features/sandboxes/status';
import { disks, statuses } from './sandboxFixtures';

// The page reads the add-on's status as `darkbloom sandbox status` does
// (SandboxStatusView.swift): the same headline and level, and the same choice between the add-on's
// own detail and what the state means for inference.
describe('the headline', () => {
  it.each([
    [statuses.ready, 'Ready', 'pass'],
    [statuses.running, 'Running 1 job', 'pass'],
    [{ ...statuses.ready, jobs_running: 2 }, 'Running 2 jobs', 'pass'],
    [statuses.paused, 'Paused', 'warn'],
    [statuses.downloading, 'Downloading images · Linux 42%', 'warn'],
    [statuses.waiting, 'Waiting for approval', 'warn'],
    [{ ...statuses.waiting, state: 'waitlisted' }, 'On the waitlist', 'warn'],
    [{ ...statuses.waiting, state: 'enrolling' }, 'Enrolling', 'warn'],
    [{ ...statuses.ready, state: 'updating' }, 'Updating', 'warn'],
    [{ ...statuses.ready, state: 'stopped' }, 'Stopped', 'fail'],
    [statuses.error, 'Error', 'fail'],
    [statuses.notInstalled, 'Not set up', 'info'],
    [statuses.future, 'Hibernating', 'info'],
    [{ schema: 1, state: 'cooling_down' }, 'Cooling down', 'info'],
  ] as [SandboxStatus, string, string][])('%#: %s', (status, text, tone) => {
    expect(headline(status)).toEqual({ text, tone });
  });

  it('leaves the percentage out while an image has none', () => {
    const status = {
      ...statuses.downloading,
      images: [{ platform: 'macos_arm64', state: 'downloading', progress: null }],
    };
    expect(headline(status).text).toBe('Downloading images');
    expect(headline({ ...status, images: [{ ...status.images[0], progress: 0.999 }] }).text).toBe(
      'Downloading images · macOS 99%',
    );
  });
});

describe('the line under it', () => {
  it('says what the state means for inference while jobs can run', () => {
    expect(explanation(statuses.ready)).toBe(
      'Waiting for jobs. Inference runs as usual until a job starts.',
    );
    expect(explanation(statuses.running)).toBe(
      'Inference is paused while jobs run, and resumes after the last one ends.',
    );
    expect(explanation(statuses.paused)).toBe(
      '1 job still running; it finishes normally. No new jobs until you resume.',
    );
    expect(explanation({ ...statuses.paused, jobs_running: 0 })).toBe(
      'No new jobs until you resume. Inference runs as usual.',
    );
    expect(explanation({ ...statuses.ready, state: 'stopped' })).toBe(
      'The agent is not running, so this Mac gets no jobs. Repair to start it.',
    );
  });

  it('shows the add-on’s own detail elsewhere, and the meaning when it sends none', () => {
    expect(explanation(statuses.waiting)).toBe(statuses.waiting.detail);
    expect(explanation(statuses.error)).toBe(statuses.error.detail);
    expect(explanation(statuses.downloading)).toBe('Downloading its linux image: 42%');
    expect(
      explanation({ ...statuses.ready, accepting: false, detail: 'Draining for an update' }),
    ).toBe('Draining for an update');
    expect(explanation({ ...statuses.ready, accepting: false, detail: null })).toBe(
      'Not taking jobs right now.',
    );
    expect(explanation({ schema: 1, state: 'error' })).toBe('See the logs for details.');
    expect(explanation(statuses.minimal)).toBe(
      'Waiting for jobs. Inference runs as usual until a job starts.',
    );
    expect(explanation({ schema: 2, state: 'hibernating' })).toBe(
      'Your add-on is newer than this Darkbloom CLI. Update the CLI to match it.',
    );
  });
});

it('offers the control that moves each state along', () => {
  expect(nextStep(statuses.paused)).toBe('resume');
  for (const state of ['waiting_for_approval', 'waitlisted', 'enrolling'])
    expect(nextStep({ schema: 1, state })).toBe('continue');
  for (const state of ['stopped', 'error']) expect(nextStep({ schema: 1, state })).toBe('repair');
  for (const state of ['ready', 'running', 'downloading_images', 'updating', 'hibernating'])
    expect(nextStep({ schema: 1, state })).toBe('pause');
});

it('lists free slots per platform and leaves a platform without slots out', () => {
  expect(slots(statuses.running)).toEqual([
    { platform: 'Linux', total: 1, free: 0 },
    { platform: 'macOS', total: 1, free: 1 },
  ]);
  expect(slots({ schema: 1, state: 'ready', slots: { linux: { total: 2, free: 9 } } })).toEqual([
    { platform: 'Linux', total: 2, free: 2 },
  ]);
  expect(slots(statuses.notInstalled)).toEqual([]);
  expect(slots(statuses.minimal)).toEqual([]);
  expect(reportsSlots(statuses.ready)).toBe(true);
  expect(reportsSlots(statuses.downloading)).toBe(false);
  expect(reportsSlots(statuses.waiting)).toBe(false);
});

it('names images and platforms as the CLI does', () => {
  expect(platformName('linux_arm64')).toBe('Linux');
  expect(platformName('macos')).toBe('macOS');
  expect(platformName('windows')).toBe('windows');
  expect(imageState({ platform: 'linux', state: 'downloading', progress: 0.4299 })).toBe(
    'Downloading 42%',
  );
  expect(imageState({ platform: 'linux', state: 'installed', progress: null })).toBe('Installed');
  expect(imageState({ platform: 'macos', state: 'missing', progress: null })).toBe('Missing');
  expect(percent(1)).toBe('100%');
  expect(percent(1.7)).toBe('100%');
});

it('shows work disks only with an external drive or more than one disk', () => {
  const internal = disks!.filter((disk) => disk.root_volume);
  expect(shownDisks({ ...statuses.ready, disks: internal })).toEqual([]);
  expect(shownDisks({ ...statuses.ready, disks })).toHaveLength(3);
  expect(shownDisks({ ...statuses.ready, disks: [disks![0]] })).toHaveLength(1);
  expect(
    shownDisks({
      ...statuses.ready,
      disks: [...internal, { path: '', state: 'online' }, { ...disks![0], state: '' }],
    }),
  ).toEqual([]);
  expect(shownDisks(statuses.ready)).toEqual([]);
});

it('reads `installed: false` and `not_installed` as not set up', () => {
  expect(isInstalled(statuses.notInstalled)).toBe(false);
  expect(isInstalled({ ...statuses.ready, installed: false })).toBe(false);
  expect(isInstalled({ schema: 1, state: 'not_installed' })).toBe(false);
  expect(isInstalled(statuses.minimal)).toBe(true);
  expect(isInstalled(undefined)).toBe(false);
});

it('says when the add-on last checked for updates', () => {
  expect(updateCheck(statuses.paused)).toBe('Updates automatic, not checked yet');
  expect(updateCheck(statuses.ready, 1_793_000_000 + 3 * 3600 + 59)).toBe(
    'Updates automatic, last checked 3h ago',
  );
  expect(updateCheck(statuses.ready, 1_793_000_000 + 2 * 86_400)).toBe(
    'Updates automatic, last checked 2d ago',
  );
  expect(updateCheck(statuses.ready, 1_793_000_000 + 30)).toBe(
    'Updates automatic, last checked just now',
  );
});
