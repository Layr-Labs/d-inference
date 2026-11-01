import { useEffect, useRef, useState, type RefObject } from 'react';

/**
 * requestAnimationFrame loop throttled to `interval` ms. It runs only while `active`, the
 * document is visible and the target element is on screen; `onFrame` receives elapsed seconds.
 */
export function useFrameLoop(
  target: RefObject<Element | null>,
  onFrame: (elapsed: number) => void,
  { active, interval }: { active: boolean; interval: number },
) {
  const callback = useRef(onFrame);
  const [onScreen, setOnScreen] = useState(true);
  const [hidden, setHidden] = useState(() => document.hidden);
  useEffect(() => {
    callback.current = onFrame;
  });
  useEffect(() => {
    const element = target.current;
    if (!element || typeof IntersectionObserver === 'undefined') return;
    const observer = new IntersectionObserver((entries) =>
      setOnScreen(entries[entries.length - 1]?.isIntersecting ?? true),
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [target]);
  useEffect(() => {
    const update = () => setHidden(document.hidden);
    document.addEventListener('visibilitychange', update);
    return () => document.removeEventListener('visibilitychange', update);
  }, []);
  const running = active && onScreen && !hidden;
  useEffect(() => {
    if (!running || typeof requestAnimationFrame === 'undefined') return;
    let frame = 0,
      last = 0;
    const tick = (now: number) => {
      frame = requestAnimationFrame(tick);
      if (last && now - last < interval - 2) return;
      const elapsed = last ? Math.min(now - last, 250) / 1000 : 0;
      last = now;
      callback.current(elapsed);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [running, interval]);
  return running;
}
