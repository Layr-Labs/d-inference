// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Onboarding } from '../src/renderer/components/Onboarding';
import {
  joinWaitlist,
  validEmail,
  waitlistError,
} from '../src/renderer/components/onboarding/waitlist';
import type { DesktopAPI } from '../src/shared/contracts';
import { backendWith, eightGBMac, models, operation, snapshot } from './onboardingFixtures';

const api = vi.hoisted(() => ({
  act: vi.fn(),
  read: vi.fn(),
  install: vi.fn(),
  openExternal: vi.fn(),
  onNavigate: () => () => {},
}));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.resetAllMocks();
});

function openWaitlist() {
  render(<Onboarding backend={backendWith(eightGBMac())} done={vi.fn()} />);
  fireEvent.click(screen.getByRole('button', { name: 'Start' }));
  fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
  const email = screen.getByRole('textbox', { name: 'Email address' });
  const join = (value: string, button = /Join the waitlist/) => {
    fireEvent.change(email, { target: { value } });
    fireEvent.click(screen.getByRole('button', { name: button }));
  };
  return { email, join };
}

describe('waitlist form', () => {
  it('asks for a valid email before sending anything', () => {
    const { email, join } = openWaitlist();
    join('not-an-email');
    expect(screen.getByRole('alert')).toHaveTextContent(
      'Enter a valid email address, like name@example.com.',
    );
    expect(email).toHaveAttribute('aria-invalid', 'true');
    expect(email).toHaveAccessibleDescription(
      'Enter a valid email address, like name@example.com.',
    );
    expect(api.act).not.toHaveBeenCalled();
    fireEvent.change(email, { target: { value: 'ada@' } });
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(email).toHaveAttribute('aria-invalid', 'false');
  });

  it('joins with the failed checks as reasons and confirms by email', async () => {
    api.act.mockResolvedValue(operation('succeeded'));
    const { join } = openWaitlist();
    join('  ada@example.com ');
    expect(await screen.findByRole('status')).toHaveTextContent(
      'You’re on the waitlist. We’ll email ada@example.com as soon as Darkbloom can run on this Mac.',
    );
    expect(api.act).toHaveBeenCalledWith({
      action: 'waitlist',
      email: 'ada@example.com',
      reasons: ['memory'],
    });
    expect(screen.queryByRole('textbox', { name: 'Email address' })).not.toBeInTheDocument();
  });

  it('shows an honest error when the runtime rejects the sign-up, and retries', async () => {
    api.act
      .mockRejectedValueOnce(
        new Error("Error invoking remote method 'backend:act': Error: Unknown action"),
      )
      .mockResolvedValueOnce(operation('succeeded'));
    const { join } = openWaitlist();
    join('ada@example.com');
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'We couldn’t add you to the waitlist. This version of Darkbloom doesn’t support sign-ups yet.',
    );
    expect(screen.queryByRole('status')).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /Try again/ }));
    expect(await screen.findByRole('status')).toHaveTextContent('You’re on the waitlist.');
    expect(api.act).toHaveBeenCalledTimes(2);
  });

  it('disables the button while the sign-up is in flight', async () => {
    let finish = () => {};
    api.act.mockReturnValue(
      new Promise((resolve) => (finish = () => resolve(operation('succeeded')))),
    );
    const { join } = openWaitlist();
    join('ada@example.com');
    expect(screen.getByRole('button', { name: /Join the waitlist/ })).toBeDisabled();
    finish();
    expect(await screen.findByRole('status')).toBeVisible();
  });

  it('is offered only to a Mac that failed a check', () => {
    const unchecked = snapshot({ models: models.map(({ memory_gb: _, ...model }) => model) });
    render(<Onboarding backend={backendWith(unchecked)} done={vi.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Start' }));
    fireEvent.click(screen.getByRole('button', { name: /Skip/ }));
    expect(screen.getByRole('heading', { name: 'We couldn’t confirm everything.' })).toBeVisible();
    expect(screen.queryByRole('textbox', { name: 'Email address' })).not.toBeInTheDocument();
  });
});

describe('waitlist contract', () => {
  const runtime = (overrides: Partial<DesktopAPI>) => overrides as DesktopAPI;

  it('waits for a running sign-up to succeed', async () => {
    vi.useFakeTimers();
    const read = vi
      .fn()
      .mockResolvedValueOnce(snapshot({ operations: [operation('running')] }))
      .mockResolvedValueOnce(snapshot({ operations: [operation('succeeded')] }));
    const signup = joinWaitlist(
      runtime({ act: vi.fn().mockResolvedValue(operation('running')), read }),
      'ada@example.com',
      ['memory'],
    );
    await vi.advanceTimersByTimeAsync(1500);
    await expect(signup).resolves.toBeUndefined();
    expect(read).toHaveBeenCalledTimes(2);
  });

  it('fails with the operation’s own message', async () => {
    const signup = joinWaitlist(
      runtime({
        act: vi.fn().mockResolvedValue(operation('failed', 'Coordinator request failed')),
      }),
      'ada@example.com',
      ['memory'],
    );
    await expect(signup).rejects.toThrow('Coordinator request failed');
  });

  it('gives up on an operation that never settles', async () => {
    vi.useFakeTimers();
    const signup = joinWaitlist(
      runtime({
        act: vi.fn().mockResolvedValue(operation('running')),
        read: vi.fn().mockResolvedValue(snapshot({ operations: [operation('running')] })),
      }),
      'ada@example.com',
      ['memory'],
    );
    const rejected = expect(signup).rejects.toThrow('The waitlist didn’t answer.');
    await vi.advanceTimersByTimeAsync(61_000);
    await rejected;
  });

  it('needs the desktop app', async () => {
    await expect(joinWaitlist(undefined, 'ada@example.com', [])).rejects.toThrow(
      'Open the Darkbloom app to join the waitlist.',
    );
  });

  it('turns runtime errors into plain language', () => {
    expect(waitlistError(new Error('Unsupported action'))).toBe(
      'This version of Darkbloom doesn’t support sign-ups yet.',
    );
    expect(
      waitlistError(
        new Error("Error invoking remote method 'backend:act': Error: Coordinator request failed"),
      ),
    ).toBe('Coordinator request failed');
    expect(waitlistError('offline')).toBe('Check your connection and try again.');
  });

  it('accepts ordinary addresses and rejects malformed ones', () => {
    for (const email of ['ada@example.com', 'a.b+c@mail.example.co.uk'])
      expect(validEmail(email)).toBe(true);
    for (const email of ['', 'ada', 'ada@', 'ada@example', 'a da@example.com', 'a@b@c.com'])
      expect(validEmail(email)).toBe(false);
    expect(validEmail(`${'a'.repeat(250)}@example.com`)).toBe(false);
  });
});
