import { describe, expect, it } from 'vitest';
import { chipAnatomy } from '../src/renderer/features/home/chip/anatomy';
import { contains, overlaps } from '../src/renderer/features/home/chip/geometry';
import { chipLayout } from '../src/renderer/features/home/chip/layout';
import { anatomyFromTopology } from '../src/renderer/features/home/chip/topologyAnatomy';
import { previewTopology } from '../src/renderer/previewHardware';
import type { HardwareTopology } from '../src/shared/hardware';

const range = (from: number, count: number) => Array.from({ length: count }, (_, i) => from + i);

/** A base M5: Super cores lead, and the Performance tier takes the efficiency role. */
const m5Topology: HardwareTopology = {
  chip: 'Apple M5',
  model: 'Mac17,2',
  cpu: {
    tiers: [
      { level: 0, name: 'Super', kind: 'super', cores: 4 },
      { level: 1, name: 'Performance', kind: 'performance', cores: 6 },
    ],
    clusters: [
      { id: 0, kind: 'performance', cpus: range(0, 6) },
      { id: 1, kind: 'super', cpus: range(6, 4) },
    ],
  },
  gpu: { cores: 10, groups: [10], max_mhz: 1690 },
  ane: { present: true },
  memory: { total_gb: 32, peak_bandwidth_gbps: 153 },
};

/** Two dies, each with two Performance clusters and one Efficiency cluster. */
const m3UltraTopology: HardwareTopology = {
  chip: 'Apple M3 Ultra',
  model: 'Mac15,14',
  cpu: {
    tiers: [
      { level: 0, name: 'Performance', kind: 'performance', cores: 24 },
      { level: 1, name: 'Efficiency', kind: 'efficiency', cores: 8 },
    ],
    clusters: [
      { id: 0, kind: 'efficiency', cpus: range(0, 4) },
      { id: 1, kind: 'performance', cpus: range(4, 6) },
      { id: 2, kind: 'performance', cpus: range(10, 6) },
      { id: 3, kind: 'efficiency', cpus: range(16, 4) },
      { id: 4, kind: 'performance', cpus: range(20, 6) },
      { id: 5, kind: 'performance', cpus: range(26, 6) },
    ],
  },
  gpu: { cores: 80, groups: Array(8).fill(10), max_mhz: 1398 },
  ane: { present: true },
  memory: { total_gb: 256, peak_bandwidth_gbps: 819 },
};

const SIZE = { width: 900, height: 440 };
const coresOf = (layout: ReturnType<typeof chipLayout>, kind: string) =>
  layout.tiles.filter((tile) => tile.kind === kind && !tile.filler);

describe('anatomy from topology', () => {
  it('uses the M4 Max clusters, GPU partitions, memory and bandwidth it reports', () => {
    const anatomy = anatomyFromTopology(previewTopology, 'Apple M2', 8);
    expect(anatomy).toMatchObject({
      source: 'topology',
      name: 'Apple M4 Max',
      tier: 'max',
      superCores: 0,
      performanceCores: 12,
      efficiencyCores: 4,
      gpuCores: 40,
      gpuGroups: [10, 10, 10, 10],
      gpuMaxMhz: 1578,
      memoryGb: 64,
      bandwidthGBs: 546,
    });
    expect(anatomy.clusters).toEqual([
      { kind: 'performance', cores: 6, cpus: range(4, 6), die: 0 },
      { kind: 'performance', cores: 6, cpus: range(10, 6), die: 0 },
      { kind: 'efficiency', cores: 4, cpus: range(0, 4), die: 0 },
    ]);

    const layout = chipLayout(anatomy, SIZE);
    const cpuIds = (kind: string) =>
      coresOf(layout, kind)
        .map((tile) => tile.cpu)
        .sort((a, b) => a! - b!);
    expect(cpuIds('performance')).toEqual(range(4, 12));
    expect(cpuIds('efficiency')).toEqual(range(0, 4));
    expect(coresOf(layout, 'gpu')).toHaveLength(40);
    const l2 = layout.tiles.filter((tile) => tile.kind === 'l2');
    expect(l2.map((tile) => tile.cluster)).toEqual([0, 1, 2]);
  });

  it('draws an M5 Super tier ahead of its Performance cores', () => {
    const anatomy = anatomyFromTopology(m5Topology, '', 0);
    expect(anatomy).toMatchObject({
      tier: 'base',
      superCores: 4,
      performanceCores: 6,
      efficiencyCores: 0,
      gpuCores: 10,
      gpuGroups: [10],
      memoryGb: 32,
      bandwidthGBs: 153,
    });
    expect(anatomy.clusters.map((cluster) => cluster.kind)).toEqual(['super', 'performance']);
    const layout = chipLayout(anatomy, SIZE);
    expect(coresOf(layout, 'super').map((tile) => tile.cpu)).toEqual(range(6, 4));
    expect(coresOf(layout, 'performance').map((tile) => tile.cpu)).toEqual(range(0, 6));
    for (const tile of layout.tiles)
      expect(layout.blocks.some((block) => contains(block.body, tile))).toBe(true);
  });

  it('splits an Ultra’s clusters and GPU partitions across its two dies', () => {
    const anatomy = anatomyFromTopology(m3UltraTopology, '', 0),
      layout = chipLayout(anatomy, SIZE);
    expect(anatomy.clusters.map((cluster) => `${cluster.kind[0]}${cluster.die}`)).toEqual([
      'p0',
      'p0',
      'p1',
      'p1',
      'e0',
      'e1',
    ]);
    for (const die of [0, 1]) {
      const tiles = layout.tiles.filter((tile) => tile.die === die && !tile.filler);
      expect(tiles.filter((tile) => tile.kind === 'gpu')).toHaveLength(40);
      expect(tiles.filter((tile) => tile.kind === 'performance')).toHaveLength(12);
      expect(tiles.filter((tile) => tile.kind === 'efficiency')).toHaveLength(4);
    }
    const tiles = layout.tiles;
    for (let i = 0; i < tiles.length; i++)
      for (let j = i + 1; j < tiles.length; j++) expect(overlaps(tiles[i], tiles[j])).toBe(false);
  });

  it('shows binned cores as fillers in uneven partitions and clusters', () => {
    const binned: HardwareTopology = {
      ...previewTopology,
      cpu: {
        ...previewTopology.cpu,
        clusters: [
          { id: 0, kind: 'efficiency', cpus: range(0, 4) },
          { id: 1, kind: 'performance', cpus: range(4, 6) },
          { id: 2, kind: 'performance', cpus: range(10, 5) },
        ],
      },
      gpu: { cores: 38, groups: [10, 9, 10, 9], max_mhz: 1578 },
    };
    const layout = chipLayout(anatomyFromTopology(binned, '', 0), SIZE),
      fillers = (kind: string) =>
        layout.tiles.filter((tile) => tile.kind === kind && tile.filler).length;
    expect(coresOf(layout, 'performance')).toHaveLength(11);
    expect(fillers('performance')).toBe(1);
    expect(coresOf(layout, 'gpu')).toHaveLength(38);
    expect(fillers('gpu')).toBe(2);
  });

  it('falls back to tier counts, then to the estimate, when the topology is incomplete', () => {
    const tiersOnly = anatomyFromTopology(
      { ...previewTopology, cpu: { ...previewTopology.cpu, clusters: [] } },
      '',
      0,
    );
    expect(tiersOnly).toMatchObject({ performanceCores: 12, efficiencyCores: 4 });
    expect(tiersOnly.clusters.every((cluster) => cluster.cpus.length === 0)).toBe(true);
    expect(
      coresOf(chipLayout(tiersOnly, SIZE), 'performance').every((tile) => tile.cpu === -1),
    ).toBe(true);

    const noGpu = anatomyFromTopology(
      {
        ...previewTopology,
        gpu: { cores: null, groups: [], max_mhz: null },
        memory: { total_gb: 64, peak_bandwidth_gbps: null },
      },
      '',
      0,
    );
    expect(noGpu).toMatchObject({ gpuCores: 40, gpuGroups: [20, 20], bandwidthGBs: 546 });
    expect(noGpu.gpuMaxMhz).toBeNull();
  });

  it('keeps the estimate when no topology has arrived', () => {
    const anatomy = anatomyFromTopology(null, 'Apple M4 Max', 64);
    expect(anatomy).toEqual(chipAnatomy('Apple M4 Max', 64));
    expect(anatomy).toMatchObject({ source: 'estimate', gpuGroups: [20, 20], gpuMaxMhz: null });
    expect(anatomy.clusters.map((cluster) => cluster.cores)).toEqual([6, 6, 4]);
  });
});
