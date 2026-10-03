import { describe, expect, it } from 'vitest';
import { clockTime, compact, count, money } from '../src/renderer/format';
import { validateDiscovery } from '../src/main/backend';
describe('count presentation', () => {
  it('groups whole numbers and keeps decimal-string counters exact past 2^53', () => {
    expect(count(2_297_784)).toBe('2,297,784');
    expect(count(2479.6)).toBe('2,480');
    expect(count('9007199254740993')).toBe('9,007,199,254,740,993');
    expect(count(12_345n)).toBe('12,345');
  });
  it('shows a dash for anything that is not a count, never zero', () => {
    expect(count()).toBe('—');
    expect(count(null)).toBe('—');
    expect(count(Number.NaN)).toBe('—');
    expect(count('12 tokens')).toBe('—');
    expect(count(0)).toBe('0');
  });
  it('abbreviates bigints like numbers', () => {
    expect(compact(659_500_000_000n)).toBe(compact(659_500_000_000));
  });
});
describe('clock time presentation', () => {
  const at = new Date(2026, 9, 1, 17, 4).getTime() / 1000;
  it('shows only the time on the same local day and adds the date otherwise', () => {
    const time = new Date(at * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    expect(clockTime(at, at + 3600)).toBe(time);
    expect(clockTime(at, at + 86_400)).not.toBe(time);
    expect(clockTime(at, at + 86_400)).toContain(time);
  });
});
describe('exact accounting presentation', () => {
  it('preserves integer precision beyond Number.MAX_SAFE_INTEGER', () => {
    expect(money('900719925474099100')).toBe('$900,719,925,474.10');
  });
  it('distinguishes missing earnings from zero', () => {
    expect(money()).toBe('—');
    expect(money('0')).toBe('$0.00');
    expect(money('-1250000')).toBe('−$1.25');
  });
  it('shows sub-cent amounts when asked and keeps whole-dollar truncation', () => {
    expect(money('2804', 4)).toBe('$0.0028');
    expect(money('2850', 4)).toBe('$0.0029');
    expect(money('1234567', 4)).toBe('$1.2346');
    expect(money('2403785714', 0)).toBe('$2,403');
  });
});
describe('backend discovery boundary', () => {
  it('accepts only the supported protocol and a bounded loopback port', () => {
    expect(
      validateDiscovery({ version: 1, port: 43111, pid: 42, token: 'x'.repeat(44) }).port,
    ).toBe(43111);
  });
  it.each([
    { version: 2, port: 3, pid: 4, token: 'x'.repeat(44) },
    { version: 1, port: 65536, pid: 4, token: 'x'.repeat(44) },
    { version: 1, port: 20, pid: 0, token: 'x'.repeat(44) },
    { version: 1, port: 20, pid: 4, token: '' },
  ])('rejects malformed discovery %j', (value) => {
    expect(() => validateDiscovery(value)).toThrow();
  });
});
