import { seeded } from '../random';

/** Signed texel in [-1, 1]: positive paints white, negative black; the magnitude is alpha. */
type Texel = (x: number, y: number) => number;
/** One texture for regions whose long axis runs along x, and the same texture turned for y. */
export interface Oriented {
  x: HTMLCanvasElement;
  y: HTMLCanvasElement;
}
export interface Textures {
  grain: HTMLCanvasElement;
  specks: HTMLCanvasElement;
  logic: HTMLCanvasElement;
  mac: HTMLCanvasElement;
  sram: Oriented;
  lanes: Oriented;
  io: Oriented;
  /** Alpha-only masks of the same structures; tinted, they shape emitted light like the texture. */
  glow: {
    logic: HTMLCanvasElement;
    sram: Oriented;
    lanes: Oriented;
    io: Oriented;
    dram: Oriented;
  };
}

const GRAIN = 128,
  SPECKS = 96,
  LOGIC = 96;

function bake(w: number, h: number, texel: Texel) {
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  if (!ctx) return canvas;
  const image = ctx.createImageData(w, h);
  for (let y = 0; y < h; y++)
    for (let x = 0; x < w; x++) {
      const value = Math.max(-1, Math.min(1, texel(x, y))),
        i = (y * w + x) * 4;
      image.data.fill(value > 0 ? 255 : 0, i, i + 3);
      image.data[i + 3] = Math.round(Math.abs(value) * 255);
    }
  ctx.putImageData(image, 0, 0);
  return canvas;
}

const oriented = (w: number, h: number, texel: Texel): Oriented => ({
  x: bake(w, h, texel),
  y: bake(h, w, (x, y) => texel(y, x)),
});

/** Roughly Gaussian values in [-1, 1]. */
function field(count: number, seed: number) {
  const random = seeded(seed),
    values = new Float32Array(count);
  for (let i = 0; i < count; i++) values[i] = (random() + random() + random()) / 1.5 - 1;
  return values;
}

/** Standard-cell rows: cells of random width and tone between one-pixel power rails. */
function cellRows(size: number, seed: number) {
  const random = seeded(seed),
    rows: Float32Array[] = [];
  for (let r = 0; r < size / 4; r++) {
    const row = new Float32Array(size);
    for (let x = 0; x < size;) {
      const end = Math.min(size, x + 2 + Math.floor(random() * 9)),
        tone = random() < 0.16 ? -0.32 : random() * 0.5 - 0.18;
      row.fill(tone, x, end);
      x = end;
    }
    rows.push(row);
  }
  return rows;
}

/** I/O cells repeating every six pixels along the strip: driver, gap, pre-driver, isolation. */
const ioCell: Texel = (x, y) => {
  const phase = x % 6,
    tone = phase < 2 ? 0.5 : phase === 2 ? -0.3 : phase < 5 ? 0.16 : -0.6;
  return y % 6 === 5 ? tone * 0.4 - 0.2 : tone;
};

/** Seeded device-pixel textures; theme independent, so a renderer builds them once. */
export function createTextures(): Textures {
  const grain = field(GRAIN * GRAIN, 11),
    specks = field(SPECKS * SPECKS, 23),
    scatter = seeded(29),
    particles = Array.from({ length: SPECKS * SPECKS }, () => scatter() > 0.968);
  const rows = cellRows(LOGIC, 37),
    fleck = field(LOGIC * LOGIC, 41),
    cell = (x: number, y: number) => rows[y >> 2][x];
  return {
    grain: bake(GRAIN, GRAIN, (x, y) => grain[y * GRAIN + x] * 0.8),
    specks: bake(SPECKS, SPECKS, (x, y) => {
      const value = specks[y * SPECKS + x];
      return particles[y * SPECKS + x] ? 0.3 + 0.35 * Math.abs(value) : value * 0.12;
    }),
    logic: bake(LOGIC, LOGIC, (x, y) =>
      y % 4 === 3 ? -0.36 : cell(x, y) * (y % 4 === 1 ? 1 : 0.7) + fleck[y * LOGIC + x] * 0.12,
    ),
    mac: bake(3, 3, (x, y) => (x < 2 && y < 2 ? 0.5 : -0.45)),
    sram: oriented(2, 4, (x, y) => (y === 3 ? -0.55 : x === 0 ? 0.32 : 0.08)),
    lanes: oriented(8, 1, (x) => (x === 7 ? -0.6 : x % 2 === 0 ? 0.3 : -0.2)),
    io: oriented(6, 6, ioCell),
    glow: {
      logic: bake(LOGIC, LOGIC, (x, y) =>
        y % 4 === 3 ? 0.08 : 0.3 + 1.4 * Math.max(0, cell(x, y)),
      ),
      sram: oriented(2, 4, (x, y) => (y === 3 ? 0.15 : x === 0 ? 1 : 0.55)),
      lanes: oriented(8, 1, (x) => (x === 7 ? 0.06 : x % 2 === 0 ? 1 : 0.14)),
      io: oriented(6, 6, (x, y) => Math.max(0.08, ioCell(x, y) * 2)),
      dram: oriented(1, 3, (_, y) => (y === 2 ? 0.2 : 1)),
    },
  };
}
