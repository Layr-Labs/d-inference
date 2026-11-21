import { count } from '../../format';
import { GRID_COLS, GRID_NORTH, GRID_ROWS, GRID_SOUTH } from './world-grid';

export interface Region {
  place: string;
  providers: number;
  col: number;
  row: number;
}
export interface MapCell {
  key: string;
  col: number;
  row: number;
  providers: number;
  label: string;
  level: 1 | 2 | 3 | 4;
}

export const macs = (providers: number) =>
  `${count(providers)} ${providers === 1 ? 'Mac' : 'Macs'}`;

const name = (value: unknown) => (typeof value === 'string' ? value.trim() : '');

// Only public, aggregated regions supplied by the native backend can light the map. A bucket
// without a region covers its whole country.
export function regionsFrom(value: unknown): Region[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry) => {
    if (!entry || typeof entry !== 'object') return [];
    const { latitude, longitude, providers } = entry;
    const region = name(entry.region);
    const country = name(entry.country);
    if (
      !Number.isFinite(latitude) ||
      !Number.isFinite(longitude) ||
      latitude > GRID_NORTH ||
      latitude <= GRID_SOUTH ||
      Math.abs(longitude) > 180 ||
      !Number.isSafeInteger(providers) ||
      providers <= 0 ||
      !country
    )
      return [];
    return [
      {
        place: region ? `${region}, ${country}` : country,
        providers,
        col: Math.min(GRID_COLS - 1, Math.floor(((longitude + 180) / 360) * GRID_COLS)),
        row: Math.floor(((GRID_NORTH - latitude) / (GRID_NORTH - GRID_SOUTH)) * GRID_ROWS),
      },
    ];
  });
}

// Shades of the founder's reference map: a few Macs, a cluster, a hub, a major hub.
export const cellLevel = (providers: number): MapCell['level'] =>
  providers >= 40 ? 4 : providers >= 10 ? 3 : providers >= 3 ? 2 : 1;

const byProviders = <T extends { providers: number }>(a: T, b: T) => b.providers - a.providers;

// Regions sharing a grid cell light it together, labelled by the largest. Largest cells first.
export function cellsFrom(regions: Region[]): MapCell[] {
  const grouped = new Map<string, Region[]>();
  for (const region of regions) {
    const key = `${region.col}:${region.row}`;
    grouped.set(key, [...(grouped.get(key) ?? []), region]);
  }
  return [...grouped]
    .map(([key, members]) => {
      const [top, ...nearby] = members.sort(
        (a, b) => byProviders(a, b) || a.place.localeCompare(b.place),
      );
      const providers = members.reduce((sum, region) => sum + region.providers, 0);
      return {
        key,
        col: top.col,
        row: top.row,
        providers,
        level: cellLevel(providers),
        label: nearby.length ? `${top.place} and ${nearby.length} nearby` : top.place,
      };
    })
    .sort((a, b) => byProviders(a, b) || a.label.localeCompare(b.label));
}
