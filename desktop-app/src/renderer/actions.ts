import type { Action, DesktopAPI, Operation, Snapshot } from '../shared/contracts';

const pollMs = 750;

// The runtime answers an action with an operation that may still be running, so it counts
// only once that operation has succeeded.
export async function submitAction(
  api: DesktopAPI,
  action: Action,
  {
    timeoutMs,
    timeout,
    onSubmitted,
  }: { timeoutMs: number; timeout: string; onSubmitted?: (operation: Operation) => void },
) {
  let operation: Operation | undefined = await api.act(action);
  onSubmitted?.(operation);
  const deadline = Date.now() + timeoutMs;
  while (operation?.state === 'running') {
    if (Date.now() > deadline) throw new Error(timeout);
    await new Promise((resolve) => setTimeout(resolve, pollMs));
    const id: string = operation.id;
    operation = (await api.read<Snapshot>('state')).operations.find((item) => item.id === id);
  }
  if (operation?.state !== 'succeeded') throw new Error(operation?.message || '');
}

// Electron prefixes errors that cross IPC; a runtime without the action rejects it by name.
const ipcPrefix = /^Error invoking remote method '[^']+': (?:\w*Error: )?/;
const unsupportedAction = /\b(?:Unknown|Unsupported) action\b/;

export const errorMessage = (error: unknown) =>
  error instanceof Error ? error.message.replace(ipcPrefix, '') : '';
export const unsupported = (error: unknown) => unsupportedAction.test(errorMessage(error));
