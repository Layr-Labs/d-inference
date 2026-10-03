import { useMemo, useState, type CSSProperties } from 'react';
import { Pause, Play } from 'lucide-react';
import type { DesktopAPI, Snapshot } from '../../../../shared/contracts';
import { useHardwareLoad } from '../../../hardware/useHardwareLoad';
import { useReducedMotion } from '../../../useReducedMotion';
import { ChipCanvas } from './ChipCanvas';
import { ChipReadouts } from './ChipReadouts';
import { hardwareReadout } from './hardware/readouts';
import { useChipPalette } from './hooks/useChipPalette';
import { useChipWorkload } from './hooks/useChipWorkload';
import { useHardwareFeed } from './hooks/useHardwareFeed';
import { usePoliteSummary } from './hooks/usePoliteSummary';
import { loadedModels, memoryMap } from './memoryMap';
import { css, type ChipPalette } from './palette';
import { PhaseLegend } from './PhaseLegend';
import { previewChip } from './previewChip';
import { stageText } from './stageText';
import { anatomyFromTopology } from './topologyAnatomy';
import { readVariant, writeVariant, type ChipVariant } from './variant';
import { VariantSwitch } from './VariantSwitch';
import styles from './chip.module.css';

const paletteVars = (palette: ChipPalette) =>
  ({
    '--chip-prefill': css(palette.prefill),
    '--chip-decode': css(palette.decode),
    '--chip-kv': css(palette.kv),
    '--chip-neutral': css(palette.neutral),
  }) as CSSProperties;

/**
 * Home hero: this Mac's chip drawn as an anatomy, lit by its measured load while the hardware
 * stream is fresh and by the simulated inference workload otherwise. `source` defaults to the
 * desktop bridge.
 */
export function ChipStage({
  state,
  preview,
  source,
}: {
  state: Snapshot;
  preview: boolean;
  source?: DesktopAPI;
}) {
  const load = useHardwareLoad(source);
  const override = useMemo(() => (preview ? previewChip() : null), [preview]);
  const chip = override?.chip ?? state.machine.chip,
    memoryGb = override?.memoryGb ?? (state.machine.memory_gb || state.memory.total_gb);
  // A previewed chip is not this Mac, so its measurements would light the wrong anatomy.
  const topology = override?.chip || override?.memoryGb ? null : load.topology,
    topologyKey = JSON.stringify(topology);
  const anatomy = useMemo(
    () => anatomyFromTopology(topology, chip, memoryGb),
    [topologyKey, chip, memoryGb],
  );
  const loaded = loadedModels(state.models),
    loadedKey = loaded.map((model) => `${model.id}:${model.gb}:${model.name}`).join('|');
  // Keyed by content: every snapshot is a fresh object, but the map only changes with the models.
  const memory = useMemo(() => memoryMap(anatomy.memoryGb, loaded), [anatomy.memoryGb, loadedKey]);
  const [variant, setVariant] = useState<ChipVariant>(readVariant);
  const [paused, setPaused] = useState(false);
  const reduced = useReducedMotion(),
    palette = useChipPalette();
  const { feed, live } = useHardwareFeed(load, anatomy);
  const { advance, stats, reading, powered } = useChipWorkload({
    state,
    preview,
    anatomy,
    memory,
    hardware: feed,
  });
  const readout = hardwareReadout(load.sample, live);
  const text = stageText({
    anatomy,
    memory,
    preview,
    provider: state.state,
    reading,
    stats,
    measured: live ? readout : null,
  });
  const summary = usePoliteSummary(text.summary);
  const choose = (next: ChipVariant) => {
    setVariant(next);
    writeVariant(next);
  };
  return (
    <section
      className={styles.stage}
      aria-label={`${anatomy.name} chip activity`}
      data-variant={variant}
      data-powered={powered}
      style={paletteVars(palette)}
    >
      <header className={styles.head}>
        <div className={styles.identity}>
          <h2>{anatomy.name}</h2>
          <p>
            <span>{text.memoryLine}</span>
            <span>{text.modelsLine}</span>
          </p>
        </div>
        <div className={styles.controls}>
          {preview && <VariantSwitch value={variant} onChange={choose} />}
          <button
            className={styles.iconButton}
            aria-label={paused ? 'Resume chip animation' : 'Pause chip animation'}
            onClick={() => setPaused(!paused)}
          >
            {paused ? <Play size={14} /> : <Pause size={14} />}
          </button>
        </div>
      </header>
      <div className={styles.body}>
        <ChipReadouts
          mode={text.mode}
          live={text.measured}
          hardware={anatomy.source === 'topology' ? readout : null}
          phase={stats.phase}
          tokensPerSecond={text.tokensPerSecond}
          running={text.running}
          waiting={text.waiting}
        />
        <ChipCanvas
          variant={variant}
          anatomy={anatomy}
          memory={memory}
          palette={palette}
          playing={!paused}
          motion={!reduced}
          advance={advance}
        />
        <PhaseLegend
          levels={{
            prefill: stats.prefill,
            decode: stats.decode,
            kv: stats.kv,
            traffic: stats.traffic,
            neural: stats.neural,
          }}
        />
      </div>
      <p className={styles.srOnly} aria-live="polite">
        {summary}
      </p>
    </section>
  );
}
