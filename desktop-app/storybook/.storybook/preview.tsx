import type { Preview } from '@storybook/react-vite';
import '../src/after/desktop-app/src/renderer/brand.css';
import '../src/after/desktop-app/src/renderer/styles.css';
import '../stories/support/compare.css';

document.documentElement.dataset.theme = 'dark';

const preview: Preview = {
  parameters: {
    layout: 'fullscreen',
    controls: { disable: true },
    actions: { disable: true },
    options: {
      storySort: {
        order: ['Introduction', 'Install flow', 'Flows', ['Onboarding', 'Status checks', 'Model loading', 'Autopilot'], 'App shell', 'Fixes', ['Onboarding and launch', 'Desktop runtime', 'Stats and updates', 'Earnings and sign-in', 'Sign-in dialog', 'Models', 'Studio, Cooling and Leaderboard', 'My Macs', 'Home numbers'], 'Second pass', ['Theme and layout', 'Behavior', 'Keyboard and screen readers'], 'Third pass', 'Fourth pass', 'Fifth pass', 'Internal'],
      },
    },
  },
};
export default preview;
