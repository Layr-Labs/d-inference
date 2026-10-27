import { expect, it, vi } from 'vitest';
import { signAsync } from '@electron/osx-sign';
import { desktopBuildConfig } from '../electron-builder';

vi.mock('@electron/osx-sign', () => ({ signAsync: vi.fn(async () => {}) }));

it('preserves the requested fingerprint when the builder supplies an ambiguous display name', async () => {
  const fingerprint = 'A'.repeat(40);
  const config = desktopBuildConfig({
    CSC_NAME: fingerprint,
    DARKBLOOM_PREVIEW_TEAM_ID: 'ABCDEFGHIJ',
    DARKBLOOM_PREVIEW_RUNTIME: '/tmp/runtime',
  });
  const sign = config.mac?.sign;
  if (typeof sign !== 'function') throw new Error('Missing preview signer');
  const options = {
    app: '/tmp/Darkbloom Preview.app',
    identity: 'Developer ID Application: Same Name (ABCDEFGHIJ)',
    identityValidation: false,
  };
  await sign(options, undefined as never);
  expect(signAsync).toHaveBeenCalledWith({
    ...options,
    identity: fingerprint,
    identityValidation: true,
  });
  expect(config.forceCodeSigning).toBe(true);
  expect(config.dmg?.sign).toBe(true);
  expect(desktopBuildConfig({}).mac?.sign).toBeUndefined();
});
