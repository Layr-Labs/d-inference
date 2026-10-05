// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import '@testing-library/jest-dom/vitest';
import { ChipStage } from '../src/renderer/features/home/chip/ChipStage';
import { previewAPI } from '../src/renderer/preview';
import { previewHardwareSample, previewTopology } from '../src/renderer/previewHardware';
import type { DesktopAPI, Snapshot } from '../src/shared/contracts';
import type { HardwareLoad } from '../src/shared/hardware';

beforeEach(() => window.history.replaceState({}, '', '/?preview'));
afterEach(cleanup);

async function previewState() {
  const state = await previewAPI.read<Snapshot>('state');
  return { ...state, state: 'running' as const, observed_at: Date.now() / 1000 };
}
/** The preview hardware stream's decode phase, sampled `age` seconds ago. */
function hardwareSource(age: number): DesktopAPI {
  const sample = { ...previewHardwareSample(16, true), sampled_at: Date.now() / 1000 - age };
  const load: HardwareLoad = { protocol: 1, topology: previewTopology, sample };
  return { read: vi.fn(async () => load), onHardware: () => () => {} } as unknown as DesktopAPI;
}
const stageFor = (state: Snapshot) =>
  screen.getByRole('region', { name: `${state.machine.chip} chip activity` });

describe('ChipStage', () => {
  it('shows which chip this Mac has, its memory and loaded models', async () => {
    const state = await previewState();
    render(<ChipStage state={state} preview />);
    const stage = stageFor(state);
    expect(within(stage).getByRole('heading', { name: state.machine.chip })).toBeVisible();
    expect(within(stage).getByText(`${state.machine.memory_gb} GB unified memory`)).toBeVisible();
    const loaded = state.models.filter((model) => model.loaded)[0];
    expect(within(stage).getByText(loaded.display_name, { selector: 'span' })).toBeVisible();
    expect(within(stage).getByText('Simulated activity')).toBeVisible();
    const legend = within(stage).getByRole('list', { name: 'What lights up' });
    for (const phase of ['Prefill', 'Decode', 'KV cache'])
      expect(within(legend).getByText(phase)).toBeVisible();
    expect(within(legend).queryByText('Neural Engine')).not.toBeInTheDocument();
    expect(within(legend).queryByText('Memory traffic')).not.toBeInTheDocument();
  });

  it('switches between the two variants through the URL in preview', async () => {
    const state = await previewState();
    render(<ChipStage state={state} preview />);
    const group = screen.getByRole('group', { name: 'Chip style' });
    expect(within(group).getByRole('button', { name: 'Blueprint' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    fireEvent.click(within(group).getByRole('button', { name: 'Photoreal' }));
    expect(within(group).getByRole('button', { name: 'Photoreal' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    expect(window.location.search).toBe('?preview&chip=photoreal');
    expect(stageFor(state)).toHaveAttribute('data-variant', 'photoreal');
  });

  it('opens the variant named in the URL', async () => {
    window.history.replaceState({}, '', '/?preview&chip=photoreal');
    const state = await previewState();
    render(<ChipStage state={state} preview />);
    expect(stageFor(state)).toHaveAttribute('data-variant', 'photoreal');
  });

  it('pauses and resumes the animation', async () => {
    const state = await previewState();
    render(<ChipStage state={state} preview />);
    fireEvent.click(screen.getByRole('button', { name: 'Pause chip animation' }));
    fireEvent.click(screen.getByRole('button', { name: 'Resume chip animation' }));
    expect(screen.getByRole('button', { name: 'Pause chip animation' })).toBeVisible();
  });

  it('shows placeholders instead of invented numbers for stale or stopped runtimes', async () => {
    const state = await previewState();
    const { rerender } = render(<ChipStage state={{ ...state, observed_at: 1 }} preview={false} />);
    const stage = stageFor(state);
    expect(within(stage).queryByRole('group', { name: 'Chip style' })).not.toBeInTheDocument();
    expect(within(stage).getByText('Waiting for live activity')).toBeVisible();
    expect(within(stage).queryByText('tokens per second')).not.toBeInTheDocument();
    expect(within(stage).queryByText('In progress')).not.toBeInTheDocument();
    expect(within(stage).queryByText('Waiting')).not.toBeInTheDocument();
    rerender(<ChipStage state={{ ...state, state: 'stopped' }} preview={false} />);
    expect(within(stage).getByText('Provider stopped')).toBeVisible();
    expect(stage).toHaveAttribute('data-powered', 'false');
  });

  it('reads live counts from a fresh runtime snapshot', async () => {
    const state = await previewState();
    state.activity = {
      ...state.activity,
      sampled_at: state.observed_at,
      models: [{ model: state.models[0].id, state: 'running', running: 3, waiting: 2 }],
    };
    render(<ChipStage state={state} preview={false} />);
    const stage = stageFor(state);
    expect(within(stage).getByText('Live from this Mac')).toBeVisible();
    expect(within(stage).getByText('In progress').nextSibling).toHaveTextContent('3');
    expect(within(stage).getByText('Waiting').nextSibling).toHaveTextContent('2');
  });

  it('is driven live from this Mac by fresh hardware samples', async () => {
    const state = await previewState();
    render(<ChipStage state={state} preview={false} source={hardwareSource(0)} />);
    const stage = stageFor(state);
    expect(await within(stage).findByText('Live from this Mac')).toBeVisible();
    const row = (label: string) => within(stage).getByText(label, { selector: 'dt' }).nextSibling;
    expect(row('GPU busy')).toHaveTextContent('99%');
    expect(row('GPU busy')).toHaveTextContent('Darkbloom 96%');
    expect(row('GPU clock')).toHaveTextContent('1,578 MHz');
    expect(within(stage).queryByText('Memory traffic')).not.toBeInTheDocument();
    expect(
      within(stage).getByTitle('macOS reports GPU busy for the whole GPU, not per core.'),
    ).toBeVisible();
  });

  it('withholds hardware readings when the stream is stale', async () => {
    const state = await previewState();
    const source = hardwareSource(10);
    state.activity.sampled_at = 1;
    render(<ChipStage state={state} preview={false} source={source} />);
    const stage = stageFor(state);
    await vi.waitFor(() => expect(source.read).toHaveBeenCalled());
    expect(await within(stage).findByText('GPU busy')).toBeVisible();
    expect(within(stage).getByText('Waiting for live activity')).toBeVisible();
    expect(within(stage).getByText('GPU busy').nextSibling).toHaveTextContent('—');
    expect(within(stage).queryByText('Live from this Mac')).not.toBeInTheDocument();
  });
});
