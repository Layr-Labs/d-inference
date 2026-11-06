import type { Route } from '../../../shared/contracts';
export const machineTabs = [
  { route: 'machines', label: 'Overview' },
  { route: 'models', label: 'Models' },
  { route: 'cooling', label: 'Cooling' },
  { route: 'analysis', label: 'Stats' },
  { route: 'settings', label: 'Settings' },
] as const;
export const isMachineRoute = (route: Route) =>
  machineTabs.some((tab) => tab.route === route) || route === 'studio';
// The Mac shown on the Overview route; null is This Mac. Every other machine
// route always shows This Mac.
export type MachineSelection = string | null;
export const showsLocalOverview = (route: Route, machine: MachineSelection) =>
  route === 'machines' && machine === null;
