import { useEffect, useState } from 'react';
import type { BackendState } from '../../useBackend';

type Phase = { name: 'idle' } | { name: 'linking'; earlier: Set<string> };

const idle: Phase = { name: 'idle' };

// Links this Mac with the runtime's device-code flow. The browser opens only from the link
// page button; this hook never opens it.
export function useAccountLink(backend: BackendState) {
  const [phase, setPhase] = useState<Phase>(idle);
  const [problem, setProblem] = useState('');
  const state = backend.state;
  const failed =
    phase.name === 'linking' &&
    !!state?.operations.some(
      (operation) =>
        operation.action === 'link' &&
        !phase.earlier.has(operation.id) &&
        (operation.state === 'failed' || operation.state === 'cancelled'),
    );
  useEffect(() => {
    if (!failed) return;
    setPhase(idle);
    setProblem('Linking didn’t finish. Link again to get a new code.');
  }, [failed]);

  return {
    linking: phase.name === 'linking' && !state?.linked,
    problem,
    async begin() {
      setProblem('');
      setPhase({ name: 'linking', earlier: new Set(state?.operations.map(({ id }) => id)) });
      if (!(await backend.act({ action: 'link' }))) setPhase(idle);
    },
    cancel() {
      if (phase.name !== 'linking') return;
      const running = state?.operations.find(
        (operation) => operation.action === 'link' && operation.state === 'running',
      );
      if (running?.cancellable) void backend.act({ action: 'cancel', operation: running.id });
      setPhase(idle);
    },
  };
}
export type AccountLink = ReturnType<typeof useAccountLink>;
