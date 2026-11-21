import { useEffect, useState, type RefObject } from 'react';

export interface SurfaceSize {
  width: number;
  height: number;
  dpr: number;
}
const MAX_DPR = 2;

/** Layout size of an element (unaffected by CSS transforms) and the capped device pixel ratio. */
export function useSurfaceSize(target: RefObject<HTMLElement | null>) {
  const [size, setSize] = useState<SurfaceSize>({ width: 0, height: 0, dpr: 1 });
  useEffect(() => {
    const element = target.current;
    if (!element || typeof ResizeObserver === 'undefined') return;
    const measure = () => {
      const width = element.clientWidth,
        height = element.clientHeight,
        dpr = Math.min(window.devicePixelRatio || 1, MAX_DPR);
      setSize((previous) =>
        previous.width === width && previous.height === height && previous.dpr === dpr
          ? previous
          : { width, height, dpr },
      );
    };
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    window.addEventListener('resize', measure);
    measure();
    return () => {
      observer.disconnect();
      window.removeEventListener('resize', measure);
    };
  }, [target]);
  return size;
}
