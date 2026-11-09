// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Rollback } from '../src/renderer/features/updates/Rollback';
import { backendWith, snapshot } from './onboardingFixtures';

vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api: undefined }));
afterEach(cleanup);

const offered = () => snapshot({ capabilities: ['update_rollback'], version: '0.12.1' });

it('offers nothing to a runtime without rollback', () => {
  const { container } = render(<Rollback backend={backendWith(snapshot())} />);
  expect(container).toBeEmptyDOMElement();
});

it('asks before returning to the previous release, and keeps this one on Keep', () => {
  const backend = backendWith(offered());
  render(<Rollback backend={backend} />);
  fireEvent.click(screen.getByRole('button', { name: 'Return to the previous release' }));
  const dialog = screen.getByRole('dialog', { name: 'Return to the previous release?' });
  expect(dialog).toHaveTextContent(
    'This Mac returns to the release kept for rollback once its requests finish. Automatic ' +
      'updates then skip 0.12.1; the next newer release installs normally.',
  );
  fireEvent.click(screen.getByRole('button', { name: 'Keep this release' }));
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
  expect(backend.act).not.toHaveBeenCalled();
});

it('rolls back once confirmed', () => {
  const backend = backendWith(offered());
  render(<Rollback backend={backend} />);
  fireEvent.click(screen.getByRole('button', { name: 'Return to the previous release' }));
  fireEvent.click(screen.getByRole('button', { name: 'Roll back' }));
  expect(backend.act).toHaveBeenCalledExactlyOnceWith({ action: 'update_rollback' });
  expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
});

it('waits while another action runs', () => {
  render(<Rollback backend={backendWith(offered(), { busy: true })} />);
  expect(screen.getByRole('button', { name: 'Return to the previous release' })).toBeDisabled();
});
