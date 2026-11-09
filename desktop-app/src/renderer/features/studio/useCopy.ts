import type { LocalTool } from '../../../shared/localServing';
import { useClipboard } from '../../components/useClipboard';

export type CopyTarget = 'url' | 'example' | LocalTool;

// Which of Studio's values was just copied, so only that button confirms it; a failed copy is
// reported on the page instead of claimed.
export function useCopy(report: (problem: string) => void) {
  const clipboard = useClipboard<CopyTarget>(1600);
  const copy = async (value: string, what: CopyTarget) => {
    report('');
    if (!(await clipboard.copy(value, what))) report('Couldn’t copy to the clipboard.');
  };
  return { copied: clipboard.copied, copy };
}

export type Copier = ReturnType<typeof useCopy>;
