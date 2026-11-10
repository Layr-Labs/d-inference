import { expect, it } from 'vitest';
import { approvalURL } from '../src/main/security';

// The approval page and the add-on's console open only on Darkbloom hosts over https.
it('opens https links on Darkbloom hosts', () => {
  for (const url of [
    'https://api-sandbox.darkbloom.dev/device?code=WDJB-MJHT',
    'https://api-sandbox.darkbloom.dev/macs/0b7d4e2a-91c3-4f6e-8a25-7c1d3e9f4b60',
    'https://console.darkbloom.dev/billing',
    'https://darkbloom.dev/device',
    'https://www.darkbloom.ai/',
  ])
    expect(approvalURL(url)).toBe(new URL(url).toString());
});

it('refuses anything else', () => {
  for (const value of [
    'http://api-sandbox.darkbloom.dev/device',
    'https://darkbloom.dev.example.com/device',
    'https://evildarkbloom.dev/device',
    'https://example.com/?next=https://darkbloom.dev',
    'https://user:secret@api-sandbox.darkbloom.dev/device',
    'https://user@api-sandbox.darkbloom.dev/device',
    'javascript:alert(1)',
    'file:///etc/passwd',
    'darkbloom://app/',
    'api-sandbox.darkbloom.dev/device',
    `https://api-sandbox.darkbloom.dev/${'a'.repeat(2048)}`,
    '',
    undefined,
    null,
    42,
    { toString: () => 'https://darkbloom.dev' },
  ])
    expect(() => approvalURL(value)).toThrow('Unsupported link');
});
