import { expect, it } from 'vitest';
import { effectiveRoute } from '../src/shared/localServing';
import {
  address,
  backIn,
  idleMinutes,
  keyRefusal,
  localServing,
  names,
  reach,
  servingDetail,
} from '../src/renderer/features/studio/words';
import { localSnapshot } from './studioFixtures';

it('reads local-first serving only from a runtime that offers it', () => {
  const state = localSnapshot();
  expect(localServing(state)).toBe(state.local);
  expect(localServing({ ...state, capabilities: undefined })).toBeUndefined();
  expect(localServing({ ...state, capabilities: ['autopilot'] })).toBeUndefined();
  expect(localServing({ ...state, local: undefined })).toBeUndefined();
});

it('words Both, me first by its minutes, and says when me first is off', () => {
  expect(servingDetail('both', { me_first: true, me_first_idle_minutes: 1 })).toMatch(
    /idle for 1 minute\.$/,
  );
  expect(servingDetail('both', { me_first: true, me_first_idle_minutes: 15 })).toMatch(
    /idle for 15 minutes\.$/,
  );
  expect(servingDetail('both', { me_first: false, me_first_idle_minutes: 2 })).toBe(
    'Darkbloom keeps serving while you use this Mac (me first is off).',
  );
});

it('says when Darkbloom comes back as the CLI does, from now', () => {
  expect(backIn(-5)).toBe('back any moment now');
  expect(backIn(0)).toBe('back any moment now');
  expect(backIn(59)).toBe('back in under a minute if you stay idle');
  expect(backIn(60)).toBe('back in about 1 minute if you stay idle');
  expect(backIn(100)).toBe('back in about 2 minutes if you stay idle');
  expect(backIn(3600)).toBe('back in about 1 hour if you stay idle');
  expect(backIn(7300)).toBe('back in about 2 hours 2 minutes if you stay idle');
});

it('takes whole minutes from 1 to 120', () => {
  expect(idleMinutes('1')).toBe(1);
  expect(idleMinutes(' 120 ')).toBe(120);
  for (const value of ['0', '121', '2.5', '-3', '', 'two', '1e2'])
    expect(idleMinutes(value)).toBe(undefined);
});

it('resolves an unsaved route as the CLI does', () => {
  const local = localSnapshot().local!;
  expect(effectiveRoute(local)).toBe('this-mac');
  expect(effectiveRoute({ ...local, route_key: true })).toBe('my-macs');
  expect(effectiveRoute({ ...local, route: 'my-macs-first' })).toBe('my-macs-first');
});

it('refuses what can’t be an account key, as `darkbloom route key` does', () => {
  expect(keyRefusal('')).toBe('No key was given.');
  expect(keyRefusal('sk-live-ok_123')).toBeUndefined();
  expect(keyRefusal('a\tb')).toMatch(/no spaces/);
  expect(keyRefusal('a\u007fb')).toMatch(/non-ASCII/);
  expect(keyRefusal('sk-😀')).toMatch(/non-ASCII/);
  expect(keyRefusal('dk-local-xyz')).toMatch(/this Mac’s local API key/);
  expect(keyRefusal('k'.repeat(512))).toBeUndefined();
  expect(keyRefusal('k'.repeat(513))).toMatch(/longer than any/);
});

it('names where the local API answers', () => {
  expect(reach(null)).toBe('Accessible only on this Mac.');
  expect(reach('localhost')).toBe('Accessible only on this Mac.');
  expect(reach('127.0.0.2')).toBe('Accessible only on this Mac.');
  expect(reach('::')).toBe('Accessible on your local network.');
  expect(reach('192.168.1.20')).toBe('Accessible on your local network.');
  expect(address(null, 8001)).toBe('127.0.0.1:8001');
  expect(address('fe80::1', 8001)).toBe('[fe80::1]:8001');
});

it('lists names in plain words', () => {
  expect(names([])).toBe('');
  expect(names(['A'])).toBe('A');
  expect(names(['A', 'B'])).toBe('A and B');
  expect(names(['A', 'B', 'C'])).toBe('A, B and C');
});
