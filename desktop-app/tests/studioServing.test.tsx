// @vitest-environment jsdom
import { afterEach, expect, it, vi } from 'vitest';
import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { Studio } from '../src/renderer/features/Studio';
import { backendWith } from './onboardingFixtures';
import { localSnapshot } from './studioFixtures';

const api = vi.hoisted(() => ({ read: vi.fn(), copy: vi.fn(), onNavigate: () => () => {} }));
vi.mock('../src/renderer/useBackend', () => ({ isPreview: false, api, useBackend: vi.fn() }));
afterEach(() => {
  cleanup();
  vi.resetAllMocks();
});

const apply = () => screen.getByRole('button', { name: 'Apply' });

it('offers the CLI’s three ways to serve, marks the saved one and recommends Both, me first', () => {
  render(<Studio backend={backendWith(localSnapshot())} />);
  expect(screen.getByRole('group', { name: 'How this Mac serves' })).toBeVisible();
  const onlyMe = screen.getByRole('radio', { name: 'Only me' });
  const network = screen.getByRole('radio', { name: 'Darkbloom network' });
  const both = screen.getByRole('radio', { name: 'Both, me first' });
  expect(onlyMe).toHaveAccessibleDescription(
    'Darkbloom never contacts this Mac. Your tools use this Mac’s own API.',
  );
  expect(network).toHaveAccessibleDescription('This Mac serves Darkbloom and earns while it runs.');
  expect(both).toBeChecked();
  expect(both).toHaveAccessibleDescription(
    'Recommended Saved This Mac serves Darkbloom while you aren’t using it. When you use it, ' +
      'Darkbloom traffic pauses until you’ve been idle for 2 minutes.',
  );
  // Nothing to apply until another way is chosen; applying restarts serving.
  expect(apply()).toBeDisabled();
  expect(screen.getByText('Applying restarts serving.')).toBeVisible();
  expect(screen.queryByText(/newer Darkbloom CLI/)).not.toBeInTheDocument();
});

it('applies Only me with the models serving now and says it restarts serving', () => {
  const backend = backendWith(localSnapshot());
  render(<Studio backend={backend} />);
  fireEvent.click(screen.getByRole('radio', { name: 'Only me' }));
  expect(
    screen.getByText('Applying restarts serving with GPT-OSS 20B and Gemma 4 26B.'),
  ).toBeVisible();
  fireEvent.click(apply());
  expect(backend.act).toHaveBeenCalledExactlyOnceWith({
    action: 'start',
    models: ['gpt-oss-20b', 'gemma-4-26b'],
    local: true,
  });
});

it('applies the network with `network` and Both with `endpoint`, keeping catalog models only', () => {
  const state = localSnapshot({ mode: 'local' });
  // A model found only on disk serves Only me, never the network.
  state.models = [
    ...state.models,
    {
      id: 'my-finetune',
      display_name: 'My finetune',
      size_gb: 4,
      downloaded: true,
      serving: true,
      loaded: true,
      eligible: true,
      network: false,
    },
  ];
  const backend = backendWith(state);
  render(<Studio backend={backend} />);
  fireEvent.click(screen.getByRole('radio', { name: 'Darkbloom network' }));
  expect(
    screen.getByText('Applying restarts serving with GPT-OSS 20B and Gemma 4 26B.'),
  ).toBeVisible();
  fireEvent.click(apply());
  fireEvent.click(screen.getByRole('radio', { name: 'Both, me first' }));
  fireEvent.click(apply());
  expect(vi.mocked(backend.act).mock.calls).toEqual([
    [{ action: 'start', models: ['gpt-oss-20b', 'gemma-4-26b'], network: true }],
    [{ action: 'start', models: ['gpt-oss-20b', 'gemma-4-26b'], endpoint: true }],
  ]);
});

it('asks for a model when none serves, and says a stopped Mac starts serving', () => {
  const state = localSnapshot({ mode: 'network' }, { state: 'stopped', endpoint: undefined });
  state.models = state.models.map((model) => ({ ...model, serving: false, loaded: false }));
  const backend = backendWith(state);
  render(<Studio backend={backend} />);
  expect(screen.queryByRole('combobox')).not.toBeInTheDocument();
  fireEvent.click(screen.getByRole('radio', { name: 'Only me' }));
  const model = screen.getByRole('combobox', { name: /Model/ });
  expect(model).toHaveValue('gpt-oss-20b');
  fireEvent.change(model, { target: { value: 'qwen-3.5-9b' } });
  expect(screen.getByText('Applying starts serving with Qwen 3.5 9B.')).toBeVisible();
  fireEvent.click(apply());
  expect(backend.act).toHaveBeenCalledWith({
    action: 'start',
    models: ['qwen-3.5-9b'],
    local: true,
  });
});

it('says when this Mac has no model to serve and offers no Apply', () => {
  const state = localSnapshot({ mode: null }, { state: 'stopped', endpoint: undefined });
  state.models = state.models.map((model) => ({ ...model, downloaded: false, serving: false }));
  render(<Studio backend={backendWith(state)} />);
  expect(screen.getByText('No model to serve yet. Get one in Models.')).toBeVisible();
  expect(apply()).toBeDisabled();
});

it('marks nothing saved before the first choice and preselects Both, me first', () => {
  const backend = backendWith(localSnapshot({ mode: null }));
  render(<Studio backend={backend} />);
  expect(screen.getByRole('radio', { name: 'Both, me first' })).toBeChecked();
  expect(screen.queryByText('Saved')).not.toBeInTheDocument();
  expect(
    screen.getByText(
      'No choice is saved yet. Applying restarts serving with GPT-OSS 20B and Gemma 4 26B.',
    ),
  ).toBeVisible();
  expect(apply()).toBeEnabled();
  fireEvent.click(apply());
  expect(backend.act).toHaveBeenCalledWith({
    action: 'start',
    models: ['gpt-oss-20b', 'gemma-4-26b'],
    endpoint: true,
  });
});

it('follows a choice saved elsewhere, such as by `darkbloom start --local`', () => {
  const view = render(<Studio backend={backendWith(localSnapshot())} />);
  fireEvent.click(screen.getByRole('radio', { name: 'Darkbloom network' }));
  view.rerender(<Studio backend={backendWith(localSnapshot({ mode: 'local' }))} />);
  expect(screen.getByRole('radio', { name: 'Only me' })).toBeChecked();
  expect(screen.getByRole('radio', { name: 'Only me' })).toHaveAccessibleDescription(/^Saved /);
  expect(apply()).toBeDisabled();
});

it('offers no way to serve on a paired Mac, whose pair serves its own way', () => {
  const navigate = vi.fn();
  const backend = backendWith(
    localSnapshot({}, { pair: { model: 'Qwen 3.8 27B', state: 'serving', leads: true } }),
  );
  render(<Studio backend={backend} navigate={navigate} />);
  for (const radio of screen.getAllByRole('radio', { name: /Only me|Darkbloom network|Both/ }))
    expect(radio).toBeDisabled();
  expect(screen.queryByRole('button', { name: 'Apply' })).not.toBeInTheDocument();
  expect(screen.getByText(/This Mac is in a pair, which serves its own way\./)).toBeVisible();
  fireEvent.click(screen.getByRole('button', { name: /Clusters/ }));
  expect(navigate).toHaveBeenCalledWith('cluster');
});

it('shows no local API parts while this Mac serves only the network', () => {
  render(
    <Studio backend={backendWith(localSnapshot({ mode: 'network' }, { endpoint: undefined }))} />,
  );
  expect(screen.getByRole('radio', { name: 'Darkbloom network' })).toBeChecked();
  for (const heading of [
    'Me first',
    'When this Mac can’t take a request',
    'Connection details',
    'Use it in your tools',
    'Make a request',
  ])
    expect(screen.queryByRole('heading', { name: heading })).not.toBeInTheDocument();
  expect(screen.queryByText('Listening')).not.toBeInTheDocument();
});

it('shows me first only for Both, me first', () => {
  const view = render(<Studio backend={backendWith(localSnapshot({ mode: 'local' }))} />);
  expect(screen.queryByRole('heading', { name: 'Me first' })).not.toBeInTheDocument();
  expect(screen.getByRole('heading', { name: 'Connection details' })).toBeVisible();
  view.rerender(<Studio backend={backendWith(localSnapshot())} />);
  expect(screen.getByRole('heading', { name: 'Me first' })).toBeVisible();
});

it('saves me first and its minutes, then offers Restart serving to apply them', async () => {
  const backend = backendWith(localSnapshot());
  render(<Studio backend={backend} />);
  const meFirst = within(screen.getByRole('region', { name: 'Me first' }));
  const save = meFirst.getByRole('button', { name: 'Save' });
  const minutes = meFirst.getByRole('spinbutton', { name: 'Back after minutes' });
  expect(
    meFirst.getByRole('switch', { name: /Pause Darkbloom while you use this Mac/ }),
  ).toBeChecked();
  expect(minutes).toHaveValue(2);
  expect(minutes).toHaveAccessibleDescription(
    'Minutes with none of your requests before Darkbloom comes back.',
  );
  expect(save).toBeDisabled();
  fireEvent.change(minutes, { target: { value: '5' } });
  await act(async () => fireEvent.click(save));
  expect(backend.act).toHaveBeenCalledWith(
    { action: 'local_settings', me_first: true, me_first_idle_minutes: 5 },
    true,
  );
  expect(meFirst.getByText('Saved. Restart serving to apply.')).toBeVisible();
  await act(async () => fireEvent.click(meFirst.getByRole('button', { name: 'Restart serving' })));
  expect(backend.act).toHaveBeenLastCalledWith({ action: 'restart' }, true);
  expect(meFirst.queryByText('Saved. Restart serving to apply.')).not.toBeInTheDocument();
});

it('stops offering Restart serving once serving restarted another way', async () => {
  const state = localSnapshot();
  const view = render(<Studio backend={backendWith(state)} />);
  const meFirst = () => within(screen.getByRole('region', { name: 'Me first' }));
  fireEvent.click(meFirst().getByRole('switch', { name: /Pause Darkbloom/ }));
  await act(async () => fireEvent.click(meFirst().getByRole('button', { name: 'Save' })));
  expect(meFirst().getByText('Saved. Restart serving to apply.')).toBeVisible();
  view.rerender(
    <Studio
      backend={backendWith({
        ...state,
        local: { ...state.local!, me_first: false },
        activity: { ...state.activity, started_at: 1_790_000_600 },
      })}
    />,
  );
  expect(meFirst().queryByText('Saved. Restart serving to apply.')).not.toBeInTheDocument();
  expect(meFirst().getByRole('switch', { name: /Pause Darkbloom/ })).not.toBeChecked();
});

it('turns me first off with the saved minutes, and needs no restart while stopped', async () => {
  const backend = backendWith(localSnapshot({ me_first_idle_minutes: 7 }, { state: 'stopped' }));
  render(<Studio backend={backend} />);
  const meFirst = within(screen.getByRole('region', { name: 'Me first' }));
  fireEvent.click(meFirst.getByRole('switch', { name: /Pause Darkbloom/ }));
  expect(meFirst.queryByRole('spinbutton')).not.toBeInTheDocument();
  expect(meFirst.getByText('Darkbloom keeps serving while you use the local API.')).toBeVisible();
  await act(async () => fireEvent.click(meFirst.getByRole('button', { name: 'Save' })));
  expect(backend.act).toHaveBeenCalledWith(
    { action: 'local_settings', me_first: false, me_first_idle_minutes: 7 },
    true,
  );
  expect(meFirst.queryByText('Saved. Restart serving to apply.')).not.toBeInTheDocument();
});

it.each(['0', '121', '2.5', ''])('refuses %j minutes before saving', (value) => {
  const backend = backendWith(localSnapshot());
  render(<Studio backend={backend} />);
  const meFirst = within(screen.getByRole('region', { name: 'Me first' }));
  const minutes = meFirst.getByRole('spinbutton', { name: 'Back after minutes' });
  fireEvent.change(minutes, { target: { value } });
  expect(minutes).toHaveAttribute('aria-invalid', 'true');
  expect(minutes).toHaveAccessibleDescription('From 1 to 120 minutes.');
  expect(meFirst.getByRole('button', { name: 'Save' })).toBeDisabled();
  expect(backend.act).not.toHaveBeenCalled();
});

it('says Darkbloom is paused for you, and when it comes back', () => {
  const state = localSnapshot();
  render(
    <Studio
      backend={backendWith({
        ...state,
        local: { ...state.local!, paused_until: state.observed_at + 100 },
      })}
    />,
  );
  expect(screen.getByRole('status')).toHaveTextContent(
    'Darkbloom is paused for you · back in about 2 minutes if you stay idle',
  );
});

it('keeps today’s Studio for a runtime without local-first serving, with one line on what a newer CLI adds', () => {
  const backend = backendWith(localSnapshot({}, { capabilities: ['autopilot'] }));
  render(<Studio backend={backend} />);
  expect(screen.getByRole('heading', { name: 'Serving mode' })).toBeVisible();
  expect(screen.getByRole('radio', { name: /Local only/ })).toBeVisible();
  expect(
    screen.getByText('A newer Darkbloom CLI adds me first, request routing and tool setup.'),
  ).toBeVisible();
  for (const heading of ['How this Mac serves', 'Me first', 'Use it in your tools'])
    expect(screen.queryByRole('heading', { name: heading })).not.toBeInTheDocument();
  expect(screen.queryByText('Listens on')).not.toBeInTheDocument();
});
