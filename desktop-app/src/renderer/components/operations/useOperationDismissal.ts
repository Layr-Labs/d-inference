import { useCallback, useEffect, useRef, useState } from 'react';
import type { Operation } from '../../../shared/contracts';

const successLifetime = 10_000;

// The operation last dismissed under `storageKey`, remembered across launches.
export function useDismissedOperation(storageKey: string) {
  const [dismissed, setDismissed] = useState(() => {
    try {
      return localStorage.getItem(storageKey) ?? '';
    } catch {
      return '';
    }
  });
  const dismiss = useCallback(
    (id: string) => {
      try {
        localStorage.setItem(storageKey, id);
      } catch {
        // The current window still remembers dismissal when storage is disabled.
      }
      setDismissed(id);
    },
    [storageKey],
  );
  return { dismissed, dismiss };
}

export function useOperationDismissal(operation?: Operation) {
  const { dismissed, dismiss } = useDismissedOperation('darkbloom.dismissed-operation');
  const deadline = useRef<{ id: string; at: number } | undefined>(undefined);

  useEffect(() => {
    if (!operation || operation.state !== 'succeeded' || operation.id === dismissed) return;
    if (deadline.current?.id !== operation.id) {
      const completedAt = operation.finished_at ? operation.finished_at * 1000 : Date.now();
      deadline.current = {
        id: operation.id,
        at: Math.min(completedAt, Date.now()) + successLifetime,
      };
    }
    const remaining = deadline.current.at - Date.now();
    if (remaining <= 0) {
      dismiss(operation.id);
      return;
    }
    const timer = setTimeout(() => dismiss(operation.id), remaining);
    return () => clearTimeout(timer);
  }, [operation?.id, operation?.state, operation?.finished_at, dismissed, dismiss]);

  return { hidden: operation?.id === dismissed, dismiss };
}
