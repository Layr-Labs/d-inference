export type RGB = readonly [number, number, number];
/** Chip colours derived from the app theme so the canvas follows light/dark and brand changes. */
export interface ChipPalette {
  dark: boolean;
  font: string;
  surface: RGB;
  /** White in dark mode, black in light mode: the base for hairlines and faint fills. */
  contrast: RGB;
  text: RGB;
  muted: RGB;
  accent: RGB;
  prefill: RGB;
  decode: RGB;
  kv: RGB;
  cpu: RGB;
  /** GPU work that is not Darkbloom's. */
  neutral: RGB;
}

export const rgba = ([r, g, b]: RGB, alpha: number) =>
  `rgba(${Math.round(r)},${Math.round(g)},${Math.round(b)},${Math.max(0, Math.min(1, alpha))})`;
export const css = (color: RGB) => rgba(color, 1);
export const mix = (a: RGB, b: RGB, t: number): RGB => [
  a[0] + (b[0] - a[0]) * t,
  a[1] + (b[1] - a[1]) * t,
  a[2] + (b[2] - a[2]) * t,
];

export function parseColor(value: string): RGB | null {
  const text = value.trim().toLowerCase();
  const hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/.exec(text)?.[1];
  if (hex) {
    const full = hex.length === 3 ? [...hex].map((c) => c + c).join('') : hex,
      channel = (i: number) => parseInt(full.slice(i, i + 2), 16);
    return [channel(0), channel(2), channel(4)];
  }
  const parts = /^(?:rgba?\()?\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)/.exec(text);
  return parts ? [Number(parts[1]), Number(parts[2]), Number(parts[3])] : null;
}

function rotateHue([r, g, b]: RGB, degrees: number): RGB {
  const [R, G, B] = [r / 255, g / 255, b / 255],
    max = Math.max(R, G, B),
    min = Math.min(R, G, B),
    l = (max + min) / 2,
    d = max - min;
  if (!d) return [r, g, b];
  const s = d / (1 - Math.abs(2 * l - 1)),
    h0 = max === R ? ((G - B) / d) % 6 : max === G ? (B - R) / d + 2 : (R - G) / d + 4,
    h = (((h0 * 60 + degrees) % 360) + 360) % 360;
  const c = (1 - Math.abs(2 * l - 1)) * s,
    x = c * (1 - Math.abs(((h / 60) % 2) - 1)),
    m = l - c / 2;
  const [r1, g1, b1] =
    h < 60
      ? [c, x, 0]
      : h < 120
        ? [x, c, 0]
        : h < 180
          ? [0, c, x]
          : h < 240
            ? [0, x, c]
            : h < 300
              ? [x, 0, c]
              : [c, 0, x];
  return [(r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255];
}

const BLACK: RGB = [0, 0, 0];
export function readChipPalette(root: HTMLElement = document.documentElement): ChipPalette {
  const style = getComputedStyle(root),
    dark = root.dataset.theme !== 'light';
  const read = (name: string, fallback: RGB) =>
    parseColor(style.getPropertyValue(name)) ?? fallback;
  const accent = read('--accent-brand', dark ? [145, 170, 255] : [11, 65, 255]),
    brand = read('--brand-blue', [11, 65, 255]),
    text = read('--text-primary', dark ? [245, 245, 245] : [23, 23, 27]),
    muted = read('--text-tertiary', dark ? [146, 146, 156] : [105, 105, 115]);
  const prefill = dark ? mix(accent, brand, 0.35) : accent;
  return {
    dark,
    font: style.fontFamily || 'Telegraf, Arial, sans-serif',
    surface: read('--panel-bg', dark ? [21, 21, 23] : [244, 244, 247]),
    contrast: read('--contrast-rgb', dark ? [255, 255, 255] : [0, 0, 0]),
    text,
    muted,
    accent,
    prefill,
    decode: dark ? rotateHue(prefill, -30) : mix(rotateHue(prefill, -30), BLACK, 0.15),
    kv: dark ? rotateHue(prefill, 45) : mix(rotateHue(prefill, 45), BLACK, 0.1),
    cpu: mix(text, accent, dark ? 0.25 : 0.35),
    neutral: mix(muted, text, 0.3),
  };
}
export const samePalette = (a: ChipPalette, b: ChipPalette) =>
  JSON.stringify(a) === JSON.stringify(b);
