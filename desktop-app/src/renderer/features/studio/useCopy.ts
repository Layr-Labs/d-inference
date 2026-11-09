import { useState } from 'react';
import type { LocalTool } from '../../../shared/localServing';
import { api } from '../../useBackend';

export type CopyTarget = 'url' | 'example' | LocalTool;

// Which value was just copied, so only that button confirms it; a failed copy is reported
// instead of claimed.
export function useCopy(report: (problem: string) => void) {
  const [copied, setCopied] = useState<CopyTarget | null>(null);
  const copy = async (value: string, what: CopyTarget) => {
    try {
      report('');
      await api?.copy(value);
      setCopied(what);
      setTimeout(() => setCopied((current) => (current === what ? null : current)), 1600);
    } catch {
      report('Couldn’t copy to the clipboard.');
    }
  };
  return { copied, copy };
}

export type Copier = ReturnType<typeof useCopy>;
