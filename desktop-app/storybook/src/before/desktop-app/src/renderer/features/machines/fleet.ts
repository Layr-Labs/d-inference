import type { CloudData, Machine, Snapshot } from '../../../shared/contracts';

// This Mac first, from native state, then the account's other Macs.
export function fleetMachines(state: Snapshot, cloud?: CloudData): Machine[] {
  return [
    { ...state.machine, status: state.state, earnings_micro_usd: cloud?.local_earnings_micro_usd },
    ...(cloud?.machines || []).filter((machine) => machine.id !== state.machine.id),
  ];
}
export const isOnline = (status: string) => ['running', 'online', 'serving'].includes(status);
export const memoryLabel = (machine: Machine) =>
  machine.memory_gb ? `${machine.memory_gb} GB` : 'Memory unknown';
