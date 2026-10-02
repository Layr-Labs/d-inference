import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const css = readFileSync("src/styles/tokens.css", "utf8");
function tokens(block: string) {
  return Object.fromEntries(block.split("\n").map((line) => line.trim()).filter((line) => line.startsWith("--")).map((line) => {
    const colon = line.indexOf(":");
    return [line.slice(0, colon), line.slice(colon + 1).trim().replace(/;$/, "")];
  }));
}
const light = tokens(css.split(":root {")[1].split("\n}")[0]);
const dark = { ...light, ...tokens(css.split(".dark {")[1].split("\n}")[0]) };
it("uses the landing page's exact wordmark and font files", () => {
  expect(readFileSync("public/brand/darkbloom.svg")).toEqual(readFileSync("../landing/public/logo.svg"));
  for (const weight of ["Regular", "Medium", "Semibold"]) {
    const file = `fonts/PPTelegraf-${weight}.woff2`;
    expect(readFileSync(`public/${file}`)).toEqual(readFileSync(`../landing/public/${file}`));
  }
});
function luminance(hex: string) {
  const values = [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16) / 255)
    .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
  return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722;
}
function contrast(a: string, b: string) {
  const values = [luminance(a), luminance(b)].sort((a, b) => b - a);
  return (values[0] + 0.05) / (values[1] + 0.05);
}
describe.each([ ["light", light], ["dark", dark] ] as const)("%s theme contrast", (_name, palette) => {
  it("keeps body, secondary text, and links readable on workspace surfaces", () => {
    for (const surface of ["--bg-primary", "--bg-secondary", "--bg-white"]) {
      for (const ink of ["--ink", "--ink-light", "--ink-faint", "--accent-brand"]) {
        expect(contrast(palette[ink], palette[surface]), `${ink} on ${surface}`).toBeGreaterThanOrEqual(4.5);
      }
    }
  });
  it("keeps white button labels readable at rest and on hover", () => {
    expect(contrast("#ffffff", palette["--action-primary"])).toBeGreaterThanOrEqual(4.5);
    expect(contrast("#ffffff", palette["--action-danger"])).toBeGreaterThanOrEqual(4.5);
    expect(contrast("#ffffff", palette["--accent-brand-hover"])).toBeGreaterThanOrEqual(4.5);
  });
});
