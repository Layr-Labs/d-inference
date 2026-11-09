import { useEffect, useState } from 'react';
import { api } from '../useBackend';

// Copies text through the main process and remembers which value was just copied (`key`, the text
// itself unless given), so only its control says Copied; with `resetMs` it says Copy again after
// that long. A copy that fails (or has no app to copy with) confirms nothing and resolves false,
// for the caller to report.
export function useClipboard<Key extends string = string>(resetMs?: number) {
  const [copied, setCopied] = useState<Key | null>(null);
  useEffect(() => {
    if (copied === null || resetMs === undefined) return;
    const timer = setTimeout(() => setCopied(null), resetMs);
    return () => clearTimeout(timer);
  }, [copied, resetMs]);
  const copy = async (text: string, key = text as Key) => {
    try {
      if (!api) throw new Error('No clipboard');
      await api.copy(text);
      setCopied(key);
      return true;
    } catch {
      setCopied(null);
      return false;
    }
  };
  return { copied, copy };
}
