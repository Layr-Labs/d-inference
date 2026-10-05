import type { Resource, Route } from '../../shared/contracts';

// Resources are requested only by screens that display them. Native code owns freshness.
export function pageResources(route: Route): Resource[] {
  switch (route) {
    case 'home':
      return ['cloud', 'network'];
    case 'machines':
    case 'earnings':
      return ['cloud'];
    case 'leaderboard':
      return ['leaderboard'];
    case 'updates':
      return ['release', 'release-history'];
    default:
      return [];
  }
}
