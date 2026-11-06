import { Notification } from 'electron';
import type { Snapshot } from '../shared/contracts';

// Notifies once per failed operation, and only while the window is hidden.
export function failedOperationNotifier(open: () => void) {
  let notified: string | undefined;
  return (state: Snapshot, windowVisible: boolean) => {
    const operation = state.operations[0];
    if (
      operation?.state === 'failed' &&
      operation.id !== notified &&
      !windowVisible &&
      Notification.isSupported()
    ) {
      notified = operation.id;
      const notification = new Notification({
        title: 'Darkbloom needs attention',
        body: 'An operation could not finish. Open Darkbloom for details.',
      });
      notification.on('click', open);
      notification.show();
    }
  };
}
