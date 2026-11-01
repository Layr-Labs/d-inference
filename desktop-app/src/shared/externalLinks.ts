import { socialLinks } from './socialLinks';

// Fixed destinations for the renderer's link targets. The main process opens these only after
// its own https and host checks (`externalURL`); the browser preview opens them in a new tab.
export const externalLinks = {
  ...socialLinks,
  console: 'https://console.darkbloom.dev',
  docs: 'https://docs.darkbloom.dev',
  community: 'https://github.com/Layr-Labs/d-inference/discussions',
  terms: 'https://www.darkbloom.ai/terms',
  privacy: 'https://www.darkbloom.ai/privacy',
} as const;
