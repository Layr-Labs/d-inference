import { expect, it } from 'vitest';
import { check, entries, restamp } from '../scripts/update-feed.mjs';

// The shape electron-builder writes for the release's dmg and zip targets.
const feed = `version: 0.1.1
files:
  - url: Darkbloom-0.1.1-arm64.dmg
    sha512: built-dmg
    size: 100
  - url: Darkbloom-0.1.1-arm64.zip
    sha512: built-zip
    size: 200
path: Darkbloom-0.1.1-arm64.dmg
sha512: built-dmg
releaseDate: '2026-10-26T21:34:57.898Z'
`;

it('restamps only the named file, including the top-level path', () => {
  const updated = restamp(feed, 'Darkbloom-0.1.1-arm64.dmg', { sha512: 'signed-dmg', size: 120 });
  expect(entries(updated)).toEqual([
    { name: 'Darkbloom-0.1.1-arm64.dmg', sha512: 'signed-dmg', size: 120 },
    { name: 'Darkbloom-0.1.1-arm64.zip', sha512: 'built-zip', size: 200 },
  ]);
  expect(updated).toContain('path: Darkbloom-0.1.1-arm64.dmg\nsha512: signed-dmg\n');
  expect(updated).toContain("releaseDate: '2026-10-26T21:34:57.898Z'");
});

it('accepts a feed whose entries match the files for this version', () => {
  const files: Record<string, { sha512: string; size: number }> = {
    'Darkbloom-0.1.1-arm64.dmg': { sha512: 'built-dmg', size: 100 },
    'Darkbloom-0.1.1-arm64.zip': { sha512: 'built-zip', size: 200 },
  };
  expect(check(feed, '0.1.1', 'Darkbloom-0.1.1-arm64.zip', (name) => files[name])).toEqual([
    'Darkbloom-0.1.1-arm64.dmg',
    'Darkbloom-0.1.1-arm64.zip',
  ]);
});

it('rejects another version, a missing zip or a stale entry', () => {
  const read = () => ({ sha512: 'built-zip', size: 200 });
  expect(() => check(feed, '0.1.2', 'Darkbloom-0.1.1-arm64.zip', read)).toThrow(
    'not for version 0.1.2',
  );
  expect(() => check(feed, '0.1.1', 'Darkbloom-0.1.2-arm64.zip', read)).toThrow(
    'does not offer Darkbloom-0.1.2-arm64.zip',
  );
  expect(() => check(feed, '0.1.1', 'Darkbloom-0.1.1-arm64.zip', read)).toThrow(
    'entry for Darkbloom-0.1.1-arm64.dmg does not match',
  );
});
