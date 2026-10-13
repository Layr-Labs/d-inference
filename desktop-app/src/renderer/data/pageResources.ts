import type { Resource, Route } from '../../shared/contracts';

// Resources are requested only by screens that display them. Native code owns freshness.
export function pageResources(route: Route): Resource[] {
  switch (route) {
    case 'home':
      return ['cloud', 'network'];
    case 'models':
      return ['network'];
    case 'machines':
    case 'earnings':
      return ['cloud'];
    // The page's network map shows the same live totals as Home's strip.
    case 'leaderboard':
      return ['leaderboard', 'network'];
    case 'updates':
      return ['release', 'release-history'];
    default:
      return [];
  }
}
