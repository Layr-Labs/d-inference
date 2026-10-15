import type { Snapshot } from '../../../../shared/contracts';
import { count } from '../../../format';
import type { ChipAnatomy } from './anatomy';
import type { HardwareReadout } from './hardware/readouts';
import type { ChipStats } from './hooks/useChipWorkload';
import type { MemoryMap } from './memoryMap';
import { PHASE_TEXT } from './phaseText';
import { providerUp, type LiveReading } from './workload/live';

const MODELS_SHOWN = 2;

/** What drives the drawing: fresh measurements from this Mac, or an explicit development preview. */
function modeText(
  provider: Snapshot['state'],
  measured: boolean,
  preview: boolean,
  fresh: boolean,
) {
  if (measured) return 'Live from this Mac';
  if (provider === 'stopped') return 'Stopped';
  if (provider === 'starting') return 'Starting…';
  if (preview) return 'Simulated activity';
  return fresh ? 'Live from this Mac' : 'Waiting for live activity';
}

/**
 * Everything the stage prints. Preview request numbers come from the simulation; live ones come
 * straight from runtime snapshots and are withheld (null) whenever they are not current.
 * `measured` is set while fresh hardware samples drive the chip.
 */
export function stageText({
  anatomy,
  memory,
  preview,
  provider,
  reading,
  stats,
  measured,
}: {
  anatomy: ChipAnatomy;
  memory: MemoryMap;
  preview: boolean;
  provider: Snapshot['state'];
  reading: LiveReading;
  stats: ChipStats;
  measured: HardwareReadout | null;
}) {
  const powered = providerUp(provider),
    live = !preview && reading.fresh,
    shown = preview ? powered : live;
  const tokensPerSecond = !shown
      ? null
      : preview
        ? stats.tokensPerSecond
        : (reading.sample?.tokensPerSecond ?? 0),
    running = !shown ? null : preview ? stats.running : reading.inputs.running,
    waiting = !shown ? null : preview ? stats.waiting : reading.inputs.waiting;
  const names = memory.models.map((model) => model.name);
  const machine = measured ? ` GPU ${measured.gpu} busy.` : '';
  // A powered chip without current numbers says why instead of claiming live activity.
  const activity = preview
    ? PHASE_TEXT[stats.phase].toLowerCase()
    : shown
      ? 'live activity'
      : provider === 'stale'
        ? 'status out of date'
        : provider === 'draining'
          ? 'finishing current requests'
          : 'waiting for live activity';
  const numbers =
    running === null
      ? ''
      : ` ${running} in progress, ${waiting} waiting, about ${
          Math.round((tokensPerSecond ?? 0) / 10) * 10
        } tokens per second.`;
  const summary = !powered
    ? `${anatomy.name}: ${provider === 'starting' ? 'starting to serve' : 'not serving'}.${machine}`
    : `${anatomy.name}: ${activity}.${numbers}${machine}`;
  // Spoken by the live region: state only. The numbers change every second and would make a
  // screen reader repeat this sentence indefinitely; they stay in `summary` and the readouts.
  const announcement = !powered
    ? `${anatomy.name}: ${provider === 'starting' ? 'starting to serve' : 'not serving'}.`
    : `${anatomy.name}: ${activity}.`;
  return {
    mode: modeText(provider, measured !== null, preview, reading.fresh),
    measured: measured !== null,
    current: shown,
    tokensPerSecond,
    running,
    waiting,
    memoryLine: anatomy.memoryGb
      ? `${count(anatomy.memoryGb)} GB unified memory`
      : 'Unified memory',
    modelsLine: names.length
      ? names.slice(0, MODELS_SHOWN).join(' · ') +
        (names.length > MODELS_SHOWN ? ` +${names.length - MODELS_SHOWN}` : '')
      : 'No model loaded',
    summary,
    announcement,
  };
}
