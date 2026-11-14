import { useEffect, useMemo, useRef, useState, type PointerEvent } from 'react';
import type { ChipAnatomy } from './anatomy';
import type { LitFrame } from './hardware/drive';
import type { Point } from './geometry';
import { useFrameLoop } from './hooks/useFrameLoop';
import { useSurfaceSize } from './hooks/useSurfaceSize';
import { chipLayout } from './layout';
import type { MemoryMap } from './memoryMap';
import type { ChipPalette } from './palette';
import { RENDERERS } from './render/renderers';
import type { ChipRenderer } from './render/types';
import type { ChipVariant } from './variant';
import styles from './chip.module.css';

const FRAME_MS = 33,
  REDUCED_FRAME_MS = 500,
  MAX_TILT_DEG = 4;

/** Hosts the canvas: owns the renderer for the variant, sizing, the frame loop and parallax. */
export function ChipCanvas({
  variant,
  anatomy,
  memory,
  palette,
  playing,
  motion,
  advance,
}: {
  variant: ChipVariant;
  anatomy: ChipAnatomy;
  memory: MemoryMap;
  palette: ChipPalette;
  playing: boolean;
  motion: boolean;
  advance: (elapsed: number) => LitFrame;
}) {
  const host = useRef<HTMLDivElement>(null),
    canvas = useRef<HTMLCanvasElement>(null),
    renderer = useRef<ChipRenderer | null>(null),
    pointer = useRef<Point | null>(null);
  const size = useSurfaceSize(host);
  const [fonts, setFonts] = useState(0),
    [drawable, setDrawable] = useState(false);
  useEffect(() => {
    const faces = document.fonts;
    if (!faces) return;
    let alive = true;
    const loaded = () => alive && setFonts((count) => count + 1);
    void faces.ready.then(loaded);
    faces.addEventListener('loadingdone', loaded);
    return () => {
      alive = false;
      faces.removeEventListener('loadingdone', loaded);
    };
  }, []);
  useEffect(() => {
    const element = canvas.current;
    if (!element || !('CanvasRenderingContext2D' in window)) return;
    const ctx = element.getContext('2d');
    if (!ctx) return;
    const instance = RENDERERS[variant](ctx);
    renderer.current = instance;
    setDrawable(true);
    return () => {
      instance.dispose();
      renderer.current = null;
    };
  }, [variant]);
  const layout = useMemo(
    () => (size.width > 0 && size.height > 0 ? chipLayout(anatomy, size) : null),
    [anatomy, size],
  );
  useEffect(() => {
    const element = canvas.current,
      instance = renderer.current;
    if (!element || !instance || !layout) return;
    element.width = Math.round(layout.width * size.dpr);
    element.height = Math.round(layout.height * size.dpr);
    instance.setScene({ anatomy, layout, memory, palette, dpr: size.dpr });
    instance.draw({ ...advance(0), motion, pointer: pointer.current });
  }, [variant, anatomy, layout, memory, palette, size.dpr, fonts, motion, advance]);
  useFrameLoop(
    canvas,
    (elapsed) => renderer.current?.draw({ ...advance(elapsed), motion, pointer: pointer.current }),
    { active: playing && drawable, interval: motion ? FRAME_MS : REDUCED_FRAME_MS },
  );

  const parallax = motion && playing;
  const track = (event: PointerEvent<HTMLDivElement>) => {
    if (!parallax) return;
    const box = event.currentTarget.getBoundingClientRect(),
      x = ((event.clientX - box.left) / box.width) * 2 - 1,
      y = ((event.clientY - box.top) / box.height) * 2 - 1;
    pointer.current = { x, y };
    event.currentTarget.style.setProperty('--tilt-x', `${(-y * MAX_TILT_DEG).toFixed(2)}deg`);
    event.currentTarget.style.setProperty('--tilt-y', `${(x * MAX_TILT_DEG).toFixed(2)}deg`);
  };
  const release = (event: PointerEvent<HTMLDivElement>) => {
    pointer.current = null;
    event.currentTarget.style.removeProperty('--tilt-x');
    event.currentTarget.style.removeProperty('--tilt-y');
  };
  return (
    <div
      ref={host}
      className={styles.viewport}
      data-variant={variant}
      data-parallax={parallax}
      onPointerMove={track}
      onPointerLeave={release}
    >
      <canvas ref={canvas} className={styles.canvas} aria-hidden="true" />
    </div>
  );
}
