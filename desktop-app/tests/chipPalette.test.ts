// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { parseColor, readChipPalette, rgba } from '../src/renderer/features/home/chip/palette';

afterEach(() => {
  document.documentElement.removeAttribute('data-theme');
  document.documentElement.removeAttribute('style');
});

describe('chip palette', () => {
  it('parses the colour formats used by the theme', () => {
    expect(parseColor('#0b41ff')).toEqual([11, 65, 255]);
    expect(parseColor(' #FFF ')).toEqual([255, 255, 255]);
    expect(parseColor('255, 255, 255')).toEqual([255, 255, 255]);
    expect(parseColor('rgba(12, 34, 56, 0.09)')).toEqual([12, 34, 56]);
    expect(parseColor('color-mix(in srgb, red, blue)')).toBeNull();
    expect(rgba([10, 20, 30], 1.4)).toBe('rgba(10,20,30,1)');
  });

  it('follows the theme and derives phase colours from the brand accent', () => {
    const root = document.documentElement;
    root.dataset.theme = 'light';
    root.style.setProperty('--accent-brand', '#0b41ff');
    root.style.setProperty('--contrast-rgb', '0, 0, 0');
    const light = readChipPalette(root);
    expect(light.dark).toBe(false);
    expect(light.accent).toEqual([11, 65, 255]);
    expect(light.prefill).toEqual([11, 65, 255]);
    expect(light.contrast).toEqual([0, 0, 0]);
    expect(light.decode).not.toEqual(light.prefill);
    expect(light.kv).not.toEqual(light.prefill);

    root.dataset.theme = 'dark';
    root.style.setProperty('--accent-brand', '#91aaff');
    const dark = readChipPalette(root);
    expect(dark.dark).toBe(true);
    expect(dark.prefill).not.toEqual(dark.accent);
    for (const channel of [...dark.prefill, ...dark.decode, ...dark.kv]) {
      expect(channel).toBeGreaterThanOrEqual(0);
      expect(channel).toBeLessThanOrEqual(255);
    }
  });
});
