import type { Route } from '../../../shared/contracts';
export const machineTabs = [
  { route: 'machines', label: 'Overview' },
  { route: 'models', label: 'Models' },
  { route: 'cooling', label: 'Cooling' },
  { route: 'analysis', label: 'Analysis' },
  { route: 'settings', label: 'Settings' },
] as const;
export const isMachineRoute = (route: Route) =>
  machineTabs.some((tab) => tab.route === route) || route === 'studio';
