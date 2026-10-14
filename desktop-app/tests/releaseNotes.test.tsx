// @vitest-environment jsdom
import { afterEach, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { ReleaseTimeline } from '../src/renderer/features/updates/ReleaseTimeline';

afterEach(cleanup);

// The shape provider 0.9.20 was published with: the signed tag's whole message, signature included.
const signedTagNotes = [
  'Provider 0.9.20',
  '',
  '* Raise the default SSD cache write budget to 4 TB per rolling day.',
  '* Add persistent cache write limits.',
  '-----BEGIN SSH SIGNATURE-----',
  'U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAgEXAMPLEEXAMPLEEXAMPLE',
  'AAAAQNbiEXAMPLEEXAMPLEEXAMPLE=',
  '-----END SSH SIGNATURE-----',
].join('\n');

const publishedAt = '2026-10-12T00:00:00Z';

const timeline = (notes: string, source: 'history' | 'latest' = 'history') =>
  render(
    <ReleaseTimeline
      installed="0.9.20"
      latest={{ version: '0.9.20', notes, published_at: publishedAt }}
      history={
        source === 'history'
          ? { history: [{ version: '0.9.20', notes, published_at: publishedAt, active: true }] }
          : undefined
      }
    />,
  );

const noteLines = (container: HTMLElement) =>
  within(container.querySelector('details')!)
    .getAllByRole('listitem')
    .map((note) => note.textContent);

it('never shows a tag signature as release notes', () => {
  const { container } = timeline(signedTagNotes);
  expect(noteLines(container)).toEqual([
    'Provider 0.9.20',
    'Raise the default SSD cache write budget to 4 TB per rolling day.',
    'Add persistent cache write limits.',
  ]);
  expect(container).not.toHaveTextContent(/SIGNATURE|U1NIU0lH/);
});

it.each(['SSH', 'PGP'])('drops an unterminated %s signature block too', (type) => {
  const { container } = timeline(`Fixes.\n-----BEGIN ${type} SIGNATURE-----\niQEzBAABCAAd`);
  expect(screen.getAllByText('Fixes.')[0]).toBeVisible();
  expect(noteLines(container)).toEqual(['Fixes.']);
  expect(container).not.toHaveTextContent(/SIGNATURE|iQEz/);
});

it.each(['history', 'latest'] as const)(
  'preserves inline and quoted marker text in %s notes',
  (source) => {
    const prose = [
      'Handle `-----BEGIN SSH SIGNATURE-----` headers safely.',
      'Mention -----BEGIN PGP SIGNATURE----- in plain prose too.',
      '`-----BEGIN SSH SIGNATURE-----`',
      '"-----BEGIN PGP SIGNATURE-----"',
      '> -----BEGIN SSH SIGNATURE-----',
      '> quoted signature example',
      '> -----END SSH SIGNATURE-----',
      'Keep -----END PGP SIGNATURE----- inline.',
      '-----BEGIN SSH SIGNATURE----- is not a delimiter line.',
      '-----BEGIN PUBLIC KEY-----',
    ];
    const { container } = timeline([...prose, '* Preserve update history.'].join('\n'), source);
    expect(noteLines(container)).toEqual([...prose, 'Preserve update history.']);
    expect(screen.getByText('Installed')).toBeVisible();
    expect(screen.getByText('Latest')).toBeVisible();
    expect(container.querySelector('time')?.textContent).toBe(
      new Date(publishedAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }),
    );
  },
);

it.each(['\n', '\r\n'])(
  'keeps surrounding notes across repeated SSH and PGP blocks (%j)',
  (newline) => {
    const { container } = timeline(
      [
        'Before both signatures.',
        '-----BEGIN SSH SIGNATURE-----',
        'U1NIU0lHAAAA',
        '-----END SSH SIGNATURE-----',
        '* Between the signatures.',
        '-----BEGIN PGP SIGNATURE-----',
        '',
        'iQEzBAABCAAd',
        '-----END PGP SIGNATURE-----',
        '* After both signatures.',
      ].join(newline),
    );
    expect(noteLines(container)).toEqual([
      'Before both signatures.',
      'Between the signatures.',
      'After both signatures.',
    ]);
  },
);

it.each(['  ', '\t', '- ', '* ', '+ ', '1. '])(
  'recognizes standalone delimiter lines with whitespace or a list prefix (%j)',
  (prefix) => {
    const { container } = timeline(
      `Before.\n${prefix}-----BEGIN SSH SIGNATURE----- \t\nU1NIU0lHAAAA\n${prefix}-----END SSH SIGNATURE----- \t\nAfter.`,
    );
    expect(noteLines(container)).toEqual(['Before.', 'After.']);
  },
);

it.each([
  ['SSH', 'PGP'],
  ['PGP', 'SSH'],
])('only a standalone matching END closes a %s block', (type, otherType) => {
  const { container } = timeline(
    [
      'Before.',
      `-----BEGIN ${type} SIGNATURE-----`,
      `-----END ${otherType} SIGNATURE-----`,
      'Still inside the signature.',
      `inline -----END ${type} SIGNATURE-----`,
      'Also inside the signature.',
      `-----END ${type} SIGNATURE-----`,
      '* Legitimate following notes.',
    ].join('\n'),
  );
  expect(noteLines(container)).toEqual(['Before.', 'Legitimate following notes.']);
});

it('treats a mismatched END without a matching END as an unterminated block', () => {
  const { container } = timeline(
    'Before.\n-----BEGIN SSH SIGNATURE-----\n-----END PGP SIGNATURE-----\nStill inside.',
  );
  expect(noteLines(container)).toEqual(['Before.']);
});

it('keeps release identity and retirement separate from signature filtering', () => {
  const { container } = render(
    <ReleaseTimeline
      installed="0.9.19"
      latest={{ version: '0.9.20' }}
      history={{
        minimum_provider_version: '0.9.20',
        history: [
          { version: '0.9.20', notes: signedTagNotes, published_at: publishedAt, active: true },
          {
            version: '0.9.19',
            notes: '-----BEGIN PGP SIGNATURE-----\niQEzBAABCAAd\n-----END PGP SIGNATURE-----',
            published_at: '2026-10-08T00:00:00Z',
            active: false,
          },
        ],
      }}
    />,
  );
  const current = screen.getByText('0.9.20').closest('li')!;
  const older = screen.getByText('0.9.19').closest('li')!;
  expect(within(current).getByText('Latest')).toBeVisible();
  expect(within(current).queryByText('Retired')).not.toBeInTheDocument();
  expect(within(older).getByText('Installed')).toBeVisible();
  expect(within(older).getByText('Retired')).toBeVisible();
  expect(within(older).getByText('Release notes haven’t been published yet.')).toBeVisible();
  expect(older.querySelector('time')?.textContent).toBe(
    new Date('2026-10-08T00:00:00Z').toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric',
    }),
  );
  expect(container).not.toHaveTextContent(/SIGNATURE|U1NIU0lH|iQEz/);
});
