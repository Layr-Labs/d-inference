import type { CSSProperties, ReactNode } from 'react';
import styles from './chat.module.css';

// Darkbloom's working indicator, from the iPhone app (`PixelLoader`): a 3×3 patch of the site's
// pixel tiles that a slow diagonal wave passes through, one wave every 1.8 s from the top-left.
// Each diagonal (row + column) lags the one before by 0.27 s. With motion reduced it holds the
// wave's frame at 0.35 s, these opacities.
const rest = [0.86, 0.46, 0.19, 0.16, 0.2];

export function PixelLoader({ size = 12 }: { size?: number }) {
  return (
    <span
      className={styles.pixels}
      style={{ '--size': `${size}px` } as CSSProperties}
      aria-hidden="true"
      data-pixel-loader
    >
      {Array.from({ length: 9 }, (_, index) => {
        const diagonal = Math.floor(index / 3) + (index % 3);
        return (
          <i key={index} style={{ '--k': diagonal, '--rest': rest[diagonal] } as CSSProperties} />
        );
      })}
    </span>
  );
}

// A label a faint band of light crosses every 2.6 s (`SweepText`): it rests at the tertiary ink
// and the band lifts it toward the primary. Static with motion reduced.
export function SweepText({ children }: { children: ReactNode }) {
  return <span className={styles.sweep}>{children}</span>;
}

// Streamed text settles as it arrives (`InkTail`): its newest `glyphs` characters start faint
// and reach full ink as more text follows, like ink drying. `end` is the length of the whole
// text the pieces come from; `settling` lets the last pieces reach full ink once it finished.
export interface Ink {
  end: number;
  glyphs: number;
  settling?: boolean;
}

const segmenter =
  typeof Intl !== 'undefined' && 'Segmenter' in Intl
    ? new Intl.Segmenter(undefined, { granularity: 'grapheme' })
    : undefined;
const graphemes = (text: string) =>
  segmenter ? Array.from(segmenter.segment(text), (part) => part.segment) : Array.from(text);

// How much ink a glyph has, by how far from the end it ends (0 for the newest).
export const inkOpacity = (fromEnd: number, glyphs: number) =>
  Math.min(1, 0.28 + (0.72 * (fromEnd + 1)) / glyphs);

// `text`, which starts at `start` in the whole, with its part inside the tail as faint glyphs.
export function inked(text: string, start: number, ink: Ink | undefined): ReactNode {
  if (!ink) return text;
  const from = ink.end - ink.glyphs;
  if (start + text.length <= from) return text;
  let cut = Math.max(0, from - start);
  // Never split a character in two.
  const code = text.charCodeAt(cut - 1);
  if (cut > 0 && code >= 0xd800 && code <= 0xdbff) cut--;
  const nodes: ReactNode[] = cut ? [text.slice(0, cut)] : [];
  let index = start + cut;
  for (const glyph of graphemes(text.slice(cut))) {
    nodes.push(
      <span
        key={index}
        className={styles.ink}
        style={{ opacity: inkOpacity(ink.end - (index + glyph.length), ink.glyphs) }}
      >
        {glyph}
      </span>,
    );
    index += glyph.length;
  }
  return nodes;
}
