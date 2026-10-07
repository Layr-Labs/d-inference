import type { Action, DesktopAPI, Operation, Snapshot } from '../shared/contracts';

// Subscribe before submitting, so a fast terminal event cannot race registration.
// Poll only after the state stream has been silent for ten seconds.
export async function submitAction(
  api: DesktopAPI,
  action: Action,
  {
    timeoutMs,
    timeout,
    onSubmitted,
  }: { timeoutMs: number; timeout: string; onSubmitted?: (operation: Operation) => void },
) {
  let operation: Operation | undefined;
  let latest: Snapshot | undefined;
  let observedAt = Date.now();
  let wake: (() => void) | undefined;
  const streamed = typeof api.onState === 'function';
  const off =
    api.onState?.((snapshot) => {
      latest = snapshot;
      observedAt = Date.now();
      wake?.();
    }) ?? (() => {});
  const deadline = Date.now() + timeoutMs;
  try {
    operation = await api.act(action);
    onSubmitted?.(operation);
    const id = operation.id;
    while (operation.state === 'running') {
      operation = latest?.operations.find((item) => item.id === id) ?? operation;
      if (operation.state !== 'running') break;
      if (Date.now() >= deadline) throw new Error(timeout);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(
          () => {
            wake = undefined;
            resolve();
          },
          Math.min(5000, deadline - Date.now()),
        );
        wake = () => {
          clearTimeout(timer);
          wake = undefined;
          resolve();
        };
      });
      if (!streamed || Date.now() - observedAt >= 10_000) {
        latest = await api.read<Snapshot>('state');
        observedAt = Date.now();
      }
    }
    if (operation.state !== 'succeeded') throw new Error(operation.message || 'Operation failed');
  } finally {
    off();
    wake = undefined;
  }
}

// Electron prefixes errors that cross IPC; a runtime without the action rejects it by name.
const ipcPrefix = /^Error invoking remote method '[^']+': (?:\w*Error: )?/;
const unsupportedAction = /\b(?:Unknown|Unsupported) action\b/;

export const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message.replace(ipcPrefix, '') : '';
export const unsupported = (error: unknown) => unsupportedAction.test(errorMessage(error));
