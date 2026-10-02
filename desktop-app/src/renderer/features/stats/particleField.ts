// Deterministic choreography: gather -> orbit a model -> fan out as token streams.
export const TAU = Math.PI * 2;
export function cubic(a: number, b: number, c: number, d: number, t: number) {
  const q = 1 - t;
  return q * q * q * a + 3 * q * q * t * b + 3 * q * t * t * c + t * t * t * d;
}
export function packetPosition(phase: number, lane: number, branch: number, time: number) {
  const cy = lane === 0 ? 0.34 : 0.73,
    coreX = 0.34;
  if (phase < 0.3) {
    const t = phase / 0.3;
    return {
      x: cubic(-0.05, 0.08, 0.19, coreX, t),
      y: cubic(0.12 + branch * 0.075, 0.9 - branch * 0.06, cy, cy, t),
      energy: t,
      output: false,
    };
  }
  if (phase < 0.52) {
    const t = (phase - 0.3) / 0.22,
      angle = t * TAU * 1.8 + branch * 0.65;
    const radius = Math.sin(Math.PI * t) * 0.065;
    return {
      x: coreX + Math.cos(angle) * radius,
      y: cy + Math.sin(angle) * radius * 1.8,
      energy: 1,
      output: false,
    };
  }
  const t = (phase - 0.52) / 0.48,
    endY = 0.1 + branch * 0.095;
  const wave = Math.sin(t * TAU * 1.7 + time * 0.7 + branch * 0.38) * Math.sin(t * Math.PI) * 0.047;
  return {
    x: cubic(coreX, 0.52, 0.68, 1.02, t),
    y: cubic(cy, cy + (lane === 0 ? -0.22 : 0.2), endY, endY, t) + wave,
    energy: 1 - t * 0.4,
    output: true,
  };
}
export function paintField(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  time: number,
  dark: boolean,
) {
  ctx.clearRect(0, 0, w, h);
  const colors = dark
    ? ['128,160,255', '174,146,255', '107,222,214']
    : ['35,83,237', '115,77,212', '20,148,157'];
  const drawDot = (x: number, y: number, r: number, color: string, opacity: number) => {
    ctx.fillStyle = `rgba(${color},${opacity})`;
    ctx.beginPath();
    ctx.arc(x * w, y * h, r, 0, TAU);
    ctx.fill();
  };
  // Depth, not noise: slow parallax stars behind the two brighter working cores.
  for (let i = 0; i < 65; i++) {
    const x = (i * 0.61803398875 + time * 0.002 * (1 + (i % 3))) % 1,
      y = (i * 0.381966) % 1;
    drawDot(x, y, i % 5 === 0 ? 1.2 : 0.7, colors[0], dark ? 0.12 : 0.1);
  }
  // Wisps describe the currents without turning the scene into a flowchart.
  for (let lane = 0; lane < 2; lane++)
    for (let branch = 0; branch < 9; branch++) {
      ctx.beginPath();
      for (let step = 0; step <= 55; step++) {
        const p = packetPosition(0.52 + (step / 55) * 0.48, lane, branch, time);
        if (step === 0) ctx.moveTo(p.x * w, p.y * h);
        else ctx.lineTo(p.x * w, p.y * h);
      }
      ctx.strokeStyle = `rgba(${colors[lane]},${dark ? 0.15 : 0.1})`;
      ctx.lineWidth = 0.7;
      ctx.stroke();
    }
  // Blooming cores: translucent halo, orbiting filaments, and a quiet bright center.
  for (let lane = 0; lane < 2; lane++) {
    const x = 0.34 * w,
      y = (lane === 0 ? 0.34 : 0.73) * h,
      r = Math.min(h * 0.12, 37);
    const breathe = 1 + Math.sin(time * 1.1 + lane * 2) * 0.08;
    const glow = ctx.createRadialGradient(x, y, 0, x, y, r * 2.8);
    glow.addColorStop(0, `rgba(${colors[lane]},${dark ? 0.32 : 0.16})`);
    glow.addColorStop(1, `rgba(${colors[lane]},0)`);
    ctx.fillStyle = glow;
    ctx.fillRect(x - r * 3, y - r * 3, r * 6, r * 6);
    for (let strand = 0; strand < 3; strand++) {
      ctx.beginPath();
      for (let i = 0; i <= 96; i++) {
        const a = (i / 96) * TAU,
          petal = 1 + 0.16 * Math.sin(a * 5 + time * 0.75 + strand);
        const xx = x + Math.cos(a + time * 0.14) * r * petal * breathe;
        const yy = y + Math.sin(a + time * 0.14) * r * petal * (0.65 + strand * 0.15) * breathe;
        if (i === 0) ctx.moveTo(xx, yy);
        else ctx.lineTo(xx, yy);
      }
      ctx.strokeStyle = `rgba(${colors[lane]},${0.2 + strand * 0.12})`;
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    for (let i = 0; i < 22; i++) {
      const a = (i / 22) * TAU + time * (lane === 0 ? 0.4 : -0.35),
        depth = (Math.sin(a) + 1) / 2;
      drawDot(
        0.34 + ((Math.cos(a) * r) / w) * breathe,
        (lane === 0 ? 0.34 : 0.73) + ((Math.sin(a) * r) / h) * 0.72,
        1 + depth,
        colors[lane],
        0.3 + depth * 0.5,
      );
    }
    drawDot(0.34, lane === 0 ? 0.34 : 0.73, 3.5, colors[lane], 0.9);
  }
  // Each input has a short tail; output spreads into a small stream of tokens.
  for (let i = 0; i < 74; i++) {
    const lane = i % 2,
      branch = (i * 7) % 9,
      phase = (time / (5.5 + (i % 4) * 0.45) + i * 0.137) % 1;
    const p = packetPosition(phase, lane, branch, time),
      color = colors[p.output && i % 5 === 0 ? 2 : lane];
    const trail = p.output ? 8 : 4;
    for (let j = trail; j >= 0; j--) {
      const past = Math.max(0, phase - j * 0.004),
        q = packetPosition(past, lane, branch, time);
      drawDot(
        q.x,
        q.y,
        (p.output ? 1.7 : 2.1) * (1 - j / (trail + 2)),
        color,
        (1 - j / (trail + 1)) * 0.8 * p.energy,
      );
    }
    if (p.output && phase > 0.93) {
      const radius = ((phase - 0.93) / 0.07) * 10;
      ctx.strokeStyle = `rgba(${color},${(1 - (phase - 0.93) / 0.07) * 0.3})`;
      ctx.lineWidth = 0.8;
      ctx.beginPath();
      ctx.arc(p.x * w, p.y * h, radius, 0, TAU);
      ctx.stroke();
    }
  }
}
