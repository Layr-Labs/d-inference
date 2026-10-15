import { useEffect, useEffectEvent, useState } from 'react';
import type { Action } from '../../../shared/contracts';
import { api, type BackendState } from '../../useBackend';
import { errorMessage, submitAction, unsupported } from '../../actions';

type Phase =
  | { name: 'idle' }
  | { name: 'linking'; earlier: Set<string>; action: Action }
  | { name: 'starting' };

const idle: Phase = { name: 'idle' };
// A start may download its models first.
const startTimeoutMs = 40 * 60_000;

// Contributing needs a linked account, so an unlinked Mac links first and starts the moment the
// account is linked. A runtime that rejects Autopilot by name leaves `rejected` set so the page
// can offer the plain start instead.
export function useStartServing(backend: BackendState, done: () => void, onRejected: () => void) {
  const [phase, setPhase] = useState<Phase>(idle);
  const [rejected, setRejected] = useState(false);
  const [problem, setProblem] = useState('');
  const state = backend.state;

  async function start(action: Action) {
    setPhase({ name: 'starting' });
    if (action.action !== 'autopilot') {
      if (await backend.act(action, true)) done();
      else setPhase(idle);
      return;
    }
    try {
      if (!api) throw new Error('Open the Darkbloom app to start serving.');
      await submitAction(api, action, {
        timeoutMs: startTimeoutMs,
        timeout: 'Starting is taking longer than expected. Check its status before retrying.',
      });
      await backend.refresh();
      done();
    } catch (error) {
      setPhase(idle);
      if (unsupported(error)) {
        setRejected(true);
        onRejected();
      } else setProblem(errorMessage(error) || 'Autopilot didn’t start. Try again.');
    }
  }
  const startLinked = useEffectEvent(start);

  const linkFailed =
    phase.name === 'linking' &&
    !!state?.operations.some(
      (operation) =>
        operation.action === 'link' &&
        !phase.earlier.has(operation.id) &&
        (operation.state === 'failed' || operation.state === 'cancelled'),
    );
  useEffect(() => {
    if (phase.name !== 'linking') return;
    if (state?.linked) void startLinked(phase.action);
    else if (linkFailed) {
      setPhase(idle);
      setProblem('Linking didn’t finish. Start again to get a new code.');
    }
  }, [phase, state?.linked, linkFailed]);

  return {
    phase: phase.name,
    rejected,
    problem,
    async serve(action: Action, needsLink: boolean) {
      setProblem('');
      if (!needsLink) return start(action);
      const earlier = new Set(state?.operations.map((operation) => operation.id));
      setPhase({ name: 'linking', earlier, action });
      if (!(await backend.act({ action: 'link' }))) setPhase(idle);
    },
    cancelLink() {
      const running = state?.operations.find(
        (operation) => operation.action === 'link' && operation.state === 'running',
      );
      if (running?.cancellable) void backend.act({ action: 'cancel', operation: running.id });
      setPhase(idle);
    },
  };
}
export type StartServing = ReturnType<typeof useStartServing>;
