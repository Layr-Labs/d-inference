import { describe, expect, it } from 'vitest';
import { money } from '../src/renderer/format';
import { validateDiscovery } from '../src/main/backend';
describe('exact accounting presentation', () => {
  it('preserves integer precision beyond Number.MAX_SAFE_INTEGER', () => {
    expect(money('900719925474099100')).toBe('$900,719,925,474.10');
  });
  it('distinguishes missing earnings from zero', () => {
    expect(money()).toBe('—');
    expect(money('0')).toBe('$0.00');
    expect(money('-1250000')).toBe('−$1.25');
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
