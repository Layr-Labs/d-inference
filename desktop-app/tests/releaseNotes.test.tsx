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

const timeline = (notes: string) =>
  render(
    <ReleaseTimeline
      installed="0.9.20"
      latest={{ version: '0.9.20' }}
      history={{
        history: [{ version: '0.9.20', notes, published_at: '2026-10-12T00:00:00Z', active: true }],
      }}
    />,
  );

it('never shows a tag signature as release notes', () => {
  const { container } = timeline(signedTagNotes);
  const notes = within(container.querySelector('details')!).getAllByRole('listitem');
  expect(notes.map((note) => note.textContent)).toEqual([
    'Provider 0.9.20',
    'Raise the default SSD cache write budget to 4 TB per rolling day.',
    'Add persistent cache write limits.',
  ]);
  expect(container).not.toHaveTextContent(/SIGNATURE|U1NIU0lH/);
});

it('drops an unterminated signature block too', () => {
  const { container } = timeline('Fixes.\n-----BEGIN PGP SIGNATURE-----\niQEzBAABCAAd');
  expect(screen.getAllByText('Fixes.')[0]).toBeVisible();
  expect(container).not.toHaveTextContent(/SIGNATURE|iQEz/);
});
