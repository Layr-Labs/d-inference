import { expect, it } from 'vitest';
import { hiddenArgument, loginItemSettings, shouldStartHidden } from '../src/main/loginLaunch';

it('starts hidden when macOS reports a login launch even without arguments', () => {
  // macOS ignores login-item `args`, so a real login launch has a bare argv.
  expect(shouldStartHidden(['/Applications/Darkbloom.app/Contents/MacOS/Darkbloom'], true)).toBe(
    true,
  );
});

it('still honours an explicit --hidden argument', () => {
  expect(shouldStartHidden(['Darkbloom', hiddenArgument], false)).toBe(true);
});

it('shows the window on an ordinary launch', () => {
  expect(shouldStartHidden(['Darkbloom'], false)).toBe(false);
});

it('registers the main app as a login item without Windows-only arguments', () => {
  expect(loginItemSettings()).toEqual({ openAtLogin: true });
  expect(loginItemSettings()).not.toHaveProperty('args');
});
