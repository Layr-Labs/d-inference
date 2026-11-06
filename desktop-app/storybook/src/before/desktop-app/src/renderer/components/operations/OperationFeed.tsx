import type { BackendState } from '../../useBackend';
import { operationLabel } from './labels';
import { OperationToast } from './OperationToast';
import { useOperationDismissal } from './useOperationDismissal';

// Mounted by App outside route content so location and timers survive navigation.
export function OperationFeed({ backend }: { backend: BackendState }) {
  const operation = backend.state?.operations.find((item) => item.action !== 'account-signin');
  const { hidden, dismiss } = useOperationDismissal(operation);
  const error = backend.error;
  if (error) {
    const matchingFailure = operation?.state === 'failed' && operation.message === error;
    return (
      <OperationToast
        state="failed"
        message={error}
        title={matchingFailure ? operationLabel(operation) : 'Action failed'}
        onClose={() => {
          backend.setError('');
          if (matchingFailure) dismiss(operation.id);
        }}
      />
    );
  }
  if (!operation || hidden) return null;
  return (
    <OperationToast
      state={operation.state}
      title={operationLabel(operation)}
      message={operation.message}
      onCancel={
        operation.state === 'running' && operation.cancellable
          ? () => void backend.act({ action: 'cancel', operation: operation.id })
          : undefined
      }
      onClose={operation.state !== 'running' ? () => dismiss(operation.id) : undefined}
    />
  );
}
