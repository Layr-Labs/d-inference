import { useState } from 'react';
import type { Action } from '../../../shared/contracts';
import { api, type BackendState } from '../../useBackend';
import { errorMessage, submitAction, unsupported } from '../../actions';

type Phase = { name: 'idle' } | { name: 'starting' };

const idle: Phase = { name: 'idle' };
// A start may download its models first.
const startTimeoutMs = 40 * 60_000;

// Starts serving once the account is linked; onboarding links it in its own step. A runtime
// that rejects Autopilot by name leaves `rejected` set so the page can offer the plain start
// instead.
export function useStartServing(backend: BackendState, done: () => void, onRejected: () => void) {
  const [phase, setPhase] = useState<Phase>(idle);
  const [rejected, setRejected] = useState(false);
  const [problem, setProblem] = useState('');

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

  return {
    phase: phase.name,
    rejected,
    problem,
    async serve(action: Action) {
      setProblem('');
      return start(action);
    },
  };
}
export type StartServing = ReturnType<typeof useStartServing>;
