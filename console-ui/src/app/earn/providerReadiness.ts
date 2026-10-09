import { HARDWARE_OPTIONS } from "./calc";

export const MIN_PROVIDER_MEMORY_GB = 48;

export const PROVIDER_HARDWARE_OPTIONS = HARDWARE_OPTIONS;

export function isProviderReadyMemory(memoryGB: number): boolean {
  return memoryGB >= MIN_PROVIDER_MEMORY_GB;
}
