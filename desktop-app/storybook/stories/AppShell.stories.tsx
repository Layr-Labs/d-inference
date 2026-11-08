import type { Meta, StoryObj } from '@storybook/react-vite';
import { within } from 'storybook/test';
import App from '../src/after/desktop-app/src/renderer/App';
import { applyTheme, savedTheme } from '../src/after/desktop-app/src/renderer/theme';
import type { Route } from '../src/after/desktop-app/src/shared/contracts';
import { AtRoute, shellFixtures } from './support/Shell';

// Every main page of the current app (the After tree) inside the real App: sidebar (navigation,
// Help, social links, account control), top bar and page, on the app's own development-preview
// fixtures. Onboarding is marked complete, so the first snapshot opens the dashboard. Each story
// opens its page through the bridge's onNavigate, as the menu bar does; the sidebar then works
// as in the app. The page fills the canvas: the window-size media queries follow the browser
// window, so resize it (or use “Home in a 940 px window”) to see the narrow layouts.
const meta: Meta = {
  title: 'App shell/Pages',
  parameters: { layout: 'fullscreen' },
  beforeEach: () => {
    const restore = shellFixtures();
    const previous = savedTheme();
    applyTheme('dark');
    return () => {
      restore();
      applyTheme(previous);
    };
  },
};
export default meta;
type Story = StoryObj;

const page = (route: Route, name: string): Story => ({
  name,
  render: () => (
    <AtRoute version="after" route={route}>
      <App />
    </AtRoute>
  ),
});

export const Home = page('home', 'Home');
export const ThisMac = page('machines', 'My Macs · This Mac overview');
export const Models = page('models', 'This Mac · Models');
export const Cooling = page('cooling', 'This Mac · Cooling');
export const Stats = page('analysis', 'This Mac · Stats');
export const Settings = page('settings', 'This Mac · Settings');
export const Studio = page('studio', 'Studio');
export const Earnings = page('earnings', 'Earnings');
export const Leaderboard = page('leaderboard', 'Leaderboard');
export const Updates = page('updates', 'Updates');

export const HomeLight: Story = {
  ...page('home', 'Home, light appearance'),
  beforeEach: () => {
    // The story-level hook runs after the meta's dark default; the meta's cleanup restores.
    applyTheme('light');
  },
};

// Home's Your Macs with This Mac stopped: each Mac card has its chevron, and This Mac's card
// offers Start serving (#1507). The story-level hook re-serves the fixtures with This Mac stopped.
export const HomeStopped: Story = {
  ...page('home', 'Home, This Mac stopped (Your Macs)'),
  beforeEach: () =>
    shellFixtures({
      snapshot: (state) => ({
        ...state,
        state: 'stopped',
        models: state.models.map((model) => ({ ...model, loaded: false })),
      }),
    }),
  play: async ({ canvasElement }) => {
    const macs = await within(canvasElement).findByRole('region', { name: 'Your Macs' }, { timeout: 8000 });
    macs.scrollIntoView({ block: 'center' });
  },
};

// An existing install on macOS 26.5 (#1506): Home's dismissible notice, and This Mac's
// Update macOS step. Home's notice stays dismissed for the session, so it is reset here.
const onMacOS26 = () => {
  const clear = () => {
    try {
      sessionStorage.removeItem('darkbloom.macos-prompt-dismissed');
    } catch {
      // Storage blocked: the notice shows anyway.
    }
  };
  clear();
  const restore = shellFixtures({ macosVersion: '26.5' });
  return () => {
    restore();
    clear();
  };
};
export const HomeMacos26: Story = { ...page('home', 'Home on macOS 26.5'), beforeEach: onMacOS26 };
export const ThisMacMacos26: Story = {
  ...page('machines', 'My Macs · This Mac on macOS 26.5'),
  beforeEach: onMacOS26,
};

export const HomeNarrow: Story = {
  name: 'Home in a 940 px window',
  render: () => (
    <div style={{ padding: 24, display: 'grid', gap: 12, color: 'var(--text-primary)' }}>
      <p style={{ margin: 0, fontSize: 13, opacity: 0.85 }}>
        The <i>Home</i> story in a 940 × 880 frame, the app's minimum window width (
        <code>minWidth: 940</code>), so the app's own narrow-window rules apply.
      </p>
      <iframe
        title="Home at 940 px"
        src="iframe.html?id=app-shell-pages--home&viewMode=story"
        style={{ width: 940, height: 880, border: '1px solid #ffffff2a', borderRadius: 8 }}
      />
    </div>
  ),
};
