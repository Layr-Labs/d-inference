import { useEffect, useRef } from 'react';
import { paintField } from './particleField';
import styles from './particleScene.module.css';

export function ParticleScene({
  animate,
  active,
  names,
}: {
  animate: boolean;
  active: boolean;
  names: string[];
}) {
  const ref = useRef<HTMLCanvasElement>(null),
    elapsed = useRef(0);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas || !('CanvasRenderingContext2D' in window)) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    let visible = true;
    let frame = 0,
      last = 0,
      painted = 0,
      w = 0,
      h = 0;
    let dark = getComputedStyle(document.documentElement).colorScheme !== 'light';
    const draw = () => paintField(ctx, w, h, elapsed.current, dark);
    const resize = () => {
      const box = canvas.getBoundingClientRect();
      w = box.width;
      h = box.height;
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = w * dpr;
      canvas.height = h * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      draw();
    };
    const observer = new ResizeObserver(resize);
    observer.observe(canvas);
    const theme = new MutationObserver(() => {
      dark = getComputedStyle(document.documentElement).colorScheme !== 'light';
      draw();
    });
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    const visibility = new IntersectionObserver((entries) => {
      visible = entries[0]?.isIntersecting ?? true;
    });
    visibility.observe(canvas);
    const tick = (at: number) => {
      if (last && visible && !document.hidden)
        elapsed.current += Math.min((at - last) / 1000, 0.06);
      last = at;
      if (at - painted >= 32 && visible && !document.hidden) {
        draw();
        painted = at;
      }
      frame = requestAnimationFrame(tick);
    };
    resize();
    if (animate) frame = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      theme.disconnect();
      visibility.disconnect();
    };
  }, [animate]);
  return (
    <div className={styles.scene} data-active={active}>
      <div className={styles.captions}>
        <span>Requests arrive</span>
        <span>Intelligence takes shape</span>
        <span>Tokens shared</span>
      </div>
      <canvas ref={ref} className={styles.canvas} aria-hidden="true" />
      <div className={styles.coreLabels}>
        <span>{names[0] || 'Model one'}</span>
        <span>{names[1] || 'Model two'}</span>
      </div>
      <span className={styles.accessible}>
        Illustrative requests gather around models and fan out into token streams.
      </span>
    </div>
  );
}
