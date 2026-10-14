import { useRef, useState } from 'react';
import type { Action, NativeModel, Snapshot } from '../../../shared/contracts';
import { errorMessage, submitAction, unsupported } from '../../actions';
import { api, type BackendState } from '../../useBackend';
import { enableAction } from './TurnOnAutopilot';

// A download, or the runtime's drain and restart when the pool is refreshed, can take a while.
const timeoutMs = 40 * 60_000;
const timeout = 'This is taking longer than expected. Check its status before retrying.';

export function describeFailure(error: unknown) {
  if (unsupported(error))
    return 'This version of Darkbloom doesn’t support that Autopilot change. Update the runtime, or turn Autopilot off to choose models yourself.';
  return errorMessage(error) || 'The change didn’t finish. Try again.';
}

// Each pool change runs as the runtime's own sequence: a model is downloaded, then joins the
// pool, and only a pool model can be pinned. `working` labels the step each model is on.
export function useModelActions(backend: BackendState) {
  const [working, setWorking] = useState<Record<string, string>>({});
  const [downloads, setDownloads] = useState<Record<string, string>>({});
  const [problem, setProblem] = useState('');
  const running = useRef(new Set<string>());
  const snapshot = backend.state!;

  const label = (key: string, text?: string) =>
    setWorking(({ [key]: _, ...rest }) => (text ? { ...rest, [key]: text } : rest));

  async function run(action: Action, model?: string) {
    if (!api) throw new Error('Open the Darkbloom app to change models.');
    if (action.action === 'autopilot' && !((await latest())?.linked ?? snapshot.linked)) {
      await submitAction(api, { action: 'link' }, { timeoutMs, timeout });
      await backend.refresh();
    }
    await submitAction(api, action, {
      timeoutMs,
      timeout,
      onSubmitted: (operation) =>
        model && setDownloads((current) => ({ ...current, [operation.id]: model })),
    });
    await backend.refresh();
  }
  const latest = async (): Promise<Snapshot | undefined> => api?.read<Snapshot>('state');

  // The label is set before any await so the row (and every model control) locks on the first
  // click; a second click while the task runs is ignored.
  async function task(key: string, first: string, steps: () => Promise<void>) {
    if (running.current.has(key)) return;
    running.current.add(key);
    label(key, first);
    setProblem('');
    try {
      await steps();
    } catch (error) {
      setProblem(describeFailure(error));
    } finally {
      running.current.delete(key);
      label(key);
    }
  }

  async function intoPool(model: NativeModel) {
    if (!model.downloaded) {
      label(model.id, 'Downloading…');
      await run({ action: 'download', model: model.id }, model.id);
    }
    if ((await latest())?.autopilot?.selected.includes(model.id)) return;
    if (!snapshot.autopilot?.enabled) return;
    label(model.id, 'Joining the pool…');
    await run({ action: 'autopilot_models' });
  }

  return {
    working,
    downloads,
    problem,
    dismiss: () => setProblem(''),
    join: (model: NativeModel) =>
      task(model.id, model.downloaded ? 'Joining the pool…' : 'Downloading…', () =>
        intoPool(model),
      ),
    // Enabling inventories eligible cached models for the pool; keep that inventory separate
    // from the serving selection so adding a member doesn't load another model at startup.
    add: (model: NativeModel) =>
      task(model.id, 'Joining the pool…', async () => {
        if (snapshot.autopilot?.enabled) return intoPool(model);
        label(model.id, 'Starting…');
        await run(enableAction(snapshot));
      }),
    pin: (model: NativeModel) =>
      task(model.id, 'Keeping in memory…', async () => {
        if (!snapshot.autopilot?.enabled) {
          label(model.id, model.downloaded ? 'Starting…' : 'Downloading…');
          await run({
            action: 'autopilot',
            models: [model.id],
            pinned: [model.id],
            downloads: model.downloaded ? [] : [model.id],
            endpoint: !!snapshot.endpoint,
          });
          return;
        }
        await intoPool(model);
        label(model.id, 'Keeping in memory…');
        await run({ action: 'autopilot_pin', models: [model.id] });
      }),
    unpin: (model: NativeModel) =>
      task(model.id, 'Updating…', async () => {
        label(model.id, 'Updating…');
        await run({ action: 'autopilot_unpin', models: [model.id] });
      }),
    remove: (model: NativeModel) =>
      task(model.id, 'Removing…', async () => {
        label(model.id, 'Removing…');
        await run({ action: 'remove', model: model.id });
      }),
    // Pause, resume, turn off, refresh the pool or turn on.
    policy: (action: Action, text: string) => task('autopilot', text, () => run(action)),
  };
}
export type ModelActions = ReturnType<typeof useModelActions>;
