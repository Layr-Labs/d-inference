import { useState } from 'react';
import type { BackendState } from '../../useBackend';

// Only show results from this attempt, never a previous code or failed login.
export function useAccountSignIn(backend: BackendState) {
  const operations = backend.state?.operations ?? [];
  const pending = operations.find((op) => op.action === 'account-signin' && op.state === 'running');
  const [ignored, setIgnored] = useState<Set<string>>(new Set());
  const [requestFailed, setRequestFailed] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const operation = operations.find((op) => op.action === 'account-signin' && !ignored.has(op.id));

  async function begin() {
    setRequestFailed(false);
    setIgnored(new Set(operations.filter((op) => op.id !== pending?.id).map((op) => op.id)));
    if (pending) return;
    setSubmitting(true);
    try {
      setRequestFailed(!(await backend.act({ action: 'account-signin' })));
    } finally {
      setSubmitting(false);
    }
  }

  return { pending, operation, requestFailed, submitting, begin };
}
