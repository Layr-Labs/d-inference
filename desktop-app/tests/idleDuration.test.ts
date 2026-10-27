import { expect, it } from 'vitest';
import {
  durationError,
  formatDuration,
  idleDraft,
  idleMinutes,
  maxIdleMinutes,
} from '../src/renderer/features/settings/idleDuration';

it('maps native idle minutes onto the switch and the simplest duration unit', () => {
  expect(idleDraft(0)).toEqual({ keepLoaded: true, amount: '1', unit: 'hours' });
  expect(idleDraft(15)).toEqual({ keepLoaded: false, amount: '15', unit: 'minutes' });
  expect(idleDraft(90)).toEqual({ keepLoaded: false, amount: '90', unit: 'minutes' });
  expect(idleDraft(240)).toEqual({ keepLoaded: false, amount: '4', unit: 'hours' });
  expect(idleDraft(maxIdleMinutes)).toEqual({ keepLoaded: false, amount: '168', unit: 'hours' });
});

it('converts custom durations to idle minutes, keeping models loaded as 0', () => {
  expect(idleMinutes({ keepLoaded: true, amount: 'not a number', unit: 'hours' })).toBe(0);
  expect(idleMinutes({ keepLoaded: false, amount: '90', unit: 'minutes' })).toBe(90);
  expect(idleMinutes({ keepLoaded: false, amount: '2', unit: 'hours' })).toBe(120);
  expect(idleMinutes({ keepLoaded: false, amount: '1.5', unit: 'hours' })).toBe(90);
  expect(idleMinutes({ keepLoaded: false, amount: '1.1', unit: 'hours' })).toBe(66);
  expect(idleMinutes({ keepLoaded: false, amount: '168', unit: 'hours' })).toBe(maxIdleMinutes);
});

it('blocks durations the native API rejects', () => {
  const invalid = [
    { amount: '', unit: 'minutes' },
    { amount: '0', unit: 'minutes' },
    { amount: '-5', unit: 'hours' },
    { amount: '0.5', unit: 'minutes' },
    { amount: '1.01', unit: 'hours' },
    { amount: String(maxIdleMinutes + 1), unit: 'minutes' },
    { amount: '169', unit: 'hours' },
  ] as const;
  for (const fields of invalid) {
    expect(durationError(fields)).toBeTypeOf('string');
    expect(idleMinutes({ keepLoaded: false, ...fields })).toBeUndefined();
  }
  expect(durationError({ amount: '1', unit: 'minutes' })).toBeUndefined();
  expect(durationError({ amount: String(maxIdleMinutes), unit: 'minutes' })).toBeUndefined();
});

it('labels quick durations compactly', () => {
  expect([15, 60, 240, 90].map(formatDuration)).toEqual(['15 min', '1 h', '4 h', '90 min']);
});
