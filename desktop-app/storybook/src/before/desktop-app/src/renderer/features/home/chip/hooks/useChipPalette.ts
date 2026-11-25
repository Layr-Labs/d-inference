import { useEffect, useState } from 'react';
import { readChipPalette, samePalette } from '../palette';

/** The chip palette, re-read whenever the app switches theme. */
export function useChipPalette() {
  const [palette, setPalette] = useState(() => readChipPalette());
  useEffect(() => {
    const root = document.documentElement,
      update = () =>
        setPalette((previous) => {
          const next = readChipPalette(root);
          return samePalette(previous, next) ? previous : next;
        });
    const observer = new MutationObserver(update);
    observer.observe(root, { attributes: true, attributeFilter: ['data-theme', 'style', 'class'] });
    update();
    return () => observer.disconnect();
  }, []);
  return palette;
}
