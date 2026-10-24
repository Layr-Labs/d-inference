import { expect, it } from 'vitest';
import { pageResources } from '../src/renderer/data/pageResources';
import { parseReleaseHistory, publishedVersions } from '../src/renderer/features/updates/version';

// DesktopResources.swift publishes this shape when the coordinator has no desktop release feed.
const nativeHistory = {
  history: [
    {
      version: '0.9.20',
      published_at: '2026-10-12T00:00:00Z',
      notes: 'Provider reliability.',
      active: true,
    },
  ],
};

it('keeps native release history without a published support policy', () => {
  const history = parseReleaseHistory(nativeHistory);
  expect(history.history.map((release) => release.version)).toEqual(['0.9.20']);
  expect(history.minimum_provider_version).toBeUndefined();
  expect(
    parseReleaseHistory({ ...nativeHistory, minimum_provider_version: null }),
  ).not.toHaveProperty('minimum_provider_version');
  // Account data still supplies the floor when the history cannot.
  expect(
    publishedVersions({
      release: { version: '0.9.20' },
      releaseHistory: parseReleaseHistory(nativeHistory),
      cloud: { minimum_provider_version: '0.9.10' },
    }),
  ).toEqual({ latest: '0.9.20', minimum: '0.9.10' });
});

it('still rejects malformed release history and support policy', () => {
  expect(() => parseReleaseHistory({})).toThrow('Missing release history');
  expect(() => parseReleaseHistory({ ...nativeHistory, minimum_provider_version: 9 })).toThrow(
    'Invalid support policy',
  );
  expect(() => parseReleaseHistory({ history: [{ version: '0.9.20' }] })).toThrow(
    'Invalid release',
  );
  expect(parseReleaseHistory({ ...nativeHistory, minimum_provider_version: '' })).toMatchObject({
    minimum_provider_version: '',
  });
});

it('loads release data for This Mac Overview so readiness can offer a required update', () => {
  expect(pageResources('machines')).toEqual(
    expect.arrayContaining(['cloud', 'release', 'release-history']),
  );
  expect(pageResources('models')).not.toContain('release');
});
