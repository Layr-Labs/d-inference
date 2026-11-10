import {
  useEffect,
  useId,
  useRef,
  type CSSProperties,
  type ReactNode,
  type RefObject,
} from 'react';
import { useReducedMotion } from '../../useReducedMotion';
import styles from './chat.module.css';

// The chat's backdrop, from the iPhone app (`LaunchHero`): the Darkbloom mark over a faint field
// of blue pixel tiles and a bloom of the brand blue. Empty, it is the home screen with the one
// line that changes every launch; once a chat has messages it stays where it is and steps back
// behind them. It rises in two staggered groups, and everything is still with motion reduced.
export function Hero({
  receded,
  tagline,
  modelLine,
  children,
}: {
  receded: boolean;
  tagline: string;
  modelLine?: string;
  children?: ReactNode;
}) {
  const reduced = useReducedMotion();
  const area = useRef<HTMLDivElement>(null);
  const mark = useRef<SVGSVGElement>(null);
  useTilt(area, mark, !receded && !reduced);
  return (
    <div
      ref={area}
      className={styles.hero}
      data-receded={receded || undefined}
      aria-hidden={receded || undefined}
    >
      <div className={styles.art}>
        <div className={styles.bloom} />
        <TileField animate={!reduced} />
        <Mark ref={mark} />
      </div>
      <div className={styles.words}>
        <p className={styles.tagline}>{tagline}</p>
        <p className={styles.modelLine}>{modelLine || ' '}</p>
        {children}
      </div>
    </div>
  );
}

// The three mark paths of landing/public/footer-logo.svg, as the iPhone app's `DarkbloomMark`.
const markPaths = [
  'M11.1024 11.4039H8.32683V16.9492H5.55061V0.309816H0V22.495H8.32683H16.6536V16.9492H11.1024V11.4039Z',
  'M19.4291 0.309816H16.6541V5.85627H19.4291V0.309816Z',
  'M13.8781 0.309816L8.4395 0.310399V3.08333H11.1025L11.1024 11.4039L16.6537 11.401L16.6541 5.85627L13.8781 5.85452V0.309816Z',
];
// The mark fills 64 × 74 points, its paths' bounds scaled to fit and centred.
const markScale = 64 / 19.4291;
const markTop = -0.309816 * markScale + (74 - (22.495 - 0.309816) * markScale) / 2;
const layers = 12;
const depth = 8;
const restDrop = 2.5;

// The pixel mark with depth (`ExtrudedMark`): the face is the logo exactly, one solid colour;
// a shallow edge underneath, darker toward the back, keeps the silhouette crisp. Tilting turns
// the mark a few degrees and swings the edge to the far side.
function Mark({ ref }: { ref: RefObject<SVGSVGElement | null> }) {
  const shape = `mark${useId().replace(/[^\w-]/g, '')}`;
  return (
    <svg
      ref={ref}
      className={styles.mark}
      viewBox="-10 -10 84 94"
      role="img"
      aria-label="Darkbloom"
      focusable="false"
    >
      <defs>
        <g
          id={shape}
          transform={`translate(0 ${markTop.toFixed(4)}) scale(${markScale.toFixed(5)})`}
        >
          {markPaths.map((path) => (
            <path key={path} d={path} />
          ))}
        </g>
      </defs>
      {Array.from({ length: layers }, (_, index) => {
        const share = (layers - index) / layers;
        return (
          <use
            key={index}
            href={`#${shape}`}
            className={styles.edge}
            style={
              {
                '--f': share,
                fill: `color-mix(in srgb, var(--mark-far) ${Math.round(share * 100)}%, var(--mark-near))`,
              } as CSSProperties
            }
          />
        );
      })}
      <use href={`#${shape}`} className={styles.face} />
    </svg>
  );
}

const clamp = (value: number) => Math.max(-1, Math.min(1, value));

// The Mac's answer to the phone's tilt: the mark turns toward the pointer while it is over the
// empty chat, drifting rather than tracking, and settles back without a bounce.
function useTilt(
  area: RefObject<HTMLElement | null>,
  mark: RefObject<SVGSVGElement | null>,
  enabled: boolean,
) {
  useEffect(() => {
    const element = area.current;
    const svg = mark.current;
    if (!element || !svg) return;
    let target = { x: 0, y: 0 };
    const tilt = { x: 0, y: 0 };
    let frame = 0;
    const apply = () => {
      svg.style.setProperty('--tx', tilt.x.toFixed(4));
      svg.style.setProperty('--ty', tilt.y.toFixed(4));
      svg.style.setProperty('--dx', `${(-tilt.x * depth).toFixed(3)}px`);
      svg.style.setProperty('--dy', `${(-tilt.y * depth + restDrop).toFixed(3)}px`);
    };
    const step = () => {
      tilt.x += (target.x - tilt.x) * 0.11;
      tilt.y += (target.y - tilt.y) * 0.11;
      apply();
      frame =
        Math.abs(target.x - tilt.x) + Math.abs(target.y - tilt.y) > 0.002
          ? requestAnimationFrame(step)
          : 0;
    };
    const wake = () => {
      if (!frame) frame = requestAnimationFrame(step);
    };
    if (!enabled) {
      apply();
      return;
    }
    const move = (event: PointerEvent) => {
      const box = svg.getBoundingClientRect();
      target = {
        x: clamp((event.clientX - (box.left + box.width / 2)) / 320) * 0.85,
        y: clamp((event.clientY - (box.top + box.height / 2)) / 320) * 0.85,
      };
      wake();
    };
    const leave = () => {
      target = { x: 0, y: 0 };
      wake();
    };
    element.addEventListener('pointermove', move);
    element.addEventListener('pointerleave', leave);
    return () => {
      cancelAnimationFrame(frame);
      element.removeEventListener('pointermove', move);
      element.removeEventListener('pointerleave', leave);
      svg.style.removeProperty('--tx');
      svg.style.removeProperty('--ty');
      svg.style.removeProperty('--dx');
      svg.style.removeProperty('--dy');
    };
  }, [area, mark, enabled]);
}

// The tile motif of darkbloom.ai (`TileField`): square tiles that brighten and fade at random,
// slowly, in Darkbloom blue, drawn in one canvas at 20 frames a second. Each tile has its own
// steady phase and period (2.7 to 4.7 s). Still with motion reduced.
const size = 240;
const tile = 9;
const step = 12;

function rgb(color: string) {
  const hex = /^#([0-9a-f]{6})$/i.exec(color.trim());
  if (hex) {
    const value = Number.parseInt(hex[1], 16);
    return [(value >> 16) & 255, (value >> 8) & 255, value & 255].join(', ');
  }
  const parts = /^rgba?\(([^)]+)\)$/i.exec(color.trim())?.[1].split(/[,\s/]+/);
  return parts && parts.length >= 3 ? parts.slice(0, 3).join(', ') : '11, 65, 255';
}

export function paintTiles(context: CanvasRenderingContext2D, seconds: number, color: string) {
  context.clearRect(0, 0, size, size);
  const count = Math.floor(size / step);
  for (let row = 0; row < count; row++)
    for (let column = 0; column < count; column++) {
      const seed = ((row * 73 + column * 151) % 997) / 997;
      const period = 2.7 + seed * 2;
      const wave = 0.5 + 0.5 * Math.sin((seconds / period + seed) * 2 * Math.PI);
      context.fillStyle = `rgba(${color}, ${(0.04 + 0.22 * wave ** 6).toFixed(3)})`;
      context.fillRect(column * step, row * step, tile, tile);
    }
}

function TileField({ animate }: { animate: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas || !('CanvasRenderingContext2D' in window)) return;
    const context = canvas.getContext('2d');
    if (!context) return;
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = size * ratio;
    canvas.height = size * ratio;
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    let color = rgb(getComputedStyle(canvas).getPropertyValue('--blue') || '#0b41ff');
    const theme = new MutationObserver(() => {
      color = rgb(getComputedStyle(canvas).getPropertyValue('--blue') || '#0b41ff');
      paintTiles(context, Date.now() / 1000, color);
    });
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    let frame = 0;
    let painted = 0;
    const tick = (at: number) => {
      if (at - painted >= 50) {
        painted = at;
        paintTiles(context, (Date.now() / 1000) % 100_000, color);
      }
      frame = requestAnimationFrame(tick);
    };
    paintTiles(context, animate ? (Date.now() / 1000) % 100_000 : 0.35, color);
    if (animate) frame = requestAnimationFrame(tick);
    return () => {
      cancelAnimationFrame(frame);
      theme.disconnect();
    };
  }, [animate]);
  return <canvas ref={ref} className={styles.tiles} aria-hidden="true" />;
}
