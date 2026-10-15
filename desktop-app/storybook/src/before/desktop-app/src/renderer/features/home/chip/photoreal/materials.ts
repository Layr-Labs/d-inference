import { mix, type ChipPalette, type RGB } from '../palette';

const WHITE: RGB = [255, 255, 255];
type Stops<T> = readonly (readonly [number, T])[];

export interface Silicon {
  fabric: RGB;
  logic: RGB;
  sram: RGB;
  alu: RGB;
  reg: RGB;
  cache: RGB;
  phy: RGB;
  mac: RGB;
  spine: RGB;
  seal: RGB;
}
/** Surface colours and lighting for one theme; the chip stays a dark physical object in both. */
export interface Materials {
  dark: boolean;
  mask: RGB;
  maskLight: RGB;
  copper: RGB;
  laminate: RGB;
  gold: Stops<string>;
  underfill: RGB;
  epoxy: RGB;
  epoxyTop: RGB;
  marking: RGB;
  ceramic: RGB;
  ceramicShade: RGB;
  terminal: RGB;
  terminalShade: RGB;
  silicon: Silicon;
  /** Thin-film interference hues washed over the die. */
  film: Stops<RGB>;
  filmStrength: number;
  /** Edge light: a cool rim in dark theme, the overhead key light in light theme. */
  rim: RGB;
  rimStrength: number;
  backlight: RGB;
  /** Strength of studio reflections on glossy epoxy and silicon. */
  gloss: number;
}
/** Luminous versions of the palette's phase colours: light emitted by the chip, not ink. */
export interface Glow {
  prefill: RGB;
  decode: RGB;
  kv: RGB;
  cpu: RGB;
  accent: RGB;
  neutral: RGB;
}

const SILICON: Silicon = {
  fabric: [25, 23, 32],
  logic: [48, 36, 48],
  sram: [30, 58, 60],
  alu: [40, 33, 84],
  reg: [36, 61, 76],
  cache: [32, 56, 70],
  phy: [64, 52, 31],
  mac: [27, 50, 43],
  spine: [12, 11, 17],
  seal: [182, 170, 148],
};
const FILM: Stops<RGB> = [
  [0, [38, 196, 186]],
  [0.27, [126, 84, 226]],
  [0.5, [226, 176, 84]],
  [0.74, [214, 92, 162]],
  [1, [56, 168, 228]],
];
const GOLD: Record<'dark' | 'light', Stops<string>> = {
  dark: [
    [0, '#3f2d0c'],
    [0.12, '#9c7a28'],
    [0.22, '#e9cf83'],
    [0.3, '#b08833'],
    [0.44, '#4f3910'],
    [0.58, '#c39d48'],
    [0.66, '#f7e3a4'],
    [0.75, '#a17a28'],
    [0.88, '#4d3812'],
    [1, '#8f6c24'],
  ],
  light: [
    [0, '#5a4214'],
    [0.12, '#b8923a'],
    [0.22, '#f6e2a2'],
    [0.3, '#c9a24c'],
    [0.44, '#6f5420'],
    [0.58, '#d9b866'],
    [0.66, '#fff1c4'],
    [0.75, '#bb9440'],
    [0.88, '#6a5020'],
    [1, '#a98535'],
  ],
};

const scale = ([r, g, b]: RGB, k: number): RGB => [
  Math.min(255, r * k),
  Math.min(255, g * k),
  Math.min(255, b * k),
];
/** The brightest colour of the same hue. */
const luminous = (color: RGB): RGB => scale(color, 255 / Math.max(1, ...color));
/** The white-hot centre of a light colour. */
export const hot = (color: RGB, amount = 0.5) => mix(color, WHITE, amount);

export function materials(palette: ChipPalette): Materials {
  const dark = palette.dark,
    lift = dark ? 1 : 1.14,
    silicon = { ...SILICON };
  for (const key of Object.keys(silicon) as (keyof Silicon)[])
    silicon[key] = scale(silicon[key], lift);
  return {
    dark,
    mask: dark ? [8, 18, 15] : [12, 26, 22],
    maskLight: dark ? [18, 37, 31] : [29, 54, 46],
    copper: [196, 122, 64],
    laminate: dark ? [120, 104, 70] : [150, 132, 96],
    gold: GOLD[dark ? 'dark' : 'light'],
    underfill: dark ? [34, 28, 20] : [44, 37, 27],
    epoxy: dark ? [8, 8, 10] : [12, 12, 14],
    epoxyTop: dark ? [27, 27, 31] : [38, 38, 43],
    marking: [214, 214, 222],
    ceramic: [176, 146, 104],
    ceramicShade: [112, 86, 56],
    terminal: [226, 226, 230],
    terminalShade: [120, 120, 128],
    silicon,
    film: FILM,
    filmStrength: dark ? 0.15 : 0.13,
    rim: dark ? mix(luminous(palette.accent), WHITE, 0.55) : WHITE,
    rimStrength: dark ? 0.7 : 0.45,
    backlight: mix(luminous(palette.accent), [70, 110, 255], 0.35),
    gloss: dark ? 0.07 : 0.11,
  };
}

/** Light-theme phase colours are saturated inks; lifted toward white they read as light. */
export function glowColors(palette: ChipPalette): Glow {
  const light = (color: RGB, lift = 0) =>
    mix(luminous(color), WHITE, palette.dark ? lift : 0.2 + lift * 0.8);
  return {
    prefill: light(palette.prefill),
    decode: light(palette.decode),
    kv: light(palette.kv),
    cpu: light(palette.cpu, 0.45),
    accent: light(palette.accent),
    neutral: light(palette.neutral, 0.2),
  };
}
