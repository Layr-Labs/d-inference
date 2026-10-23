import type { Meta, StoryObj } from '@storybook/react-vite';
import { Compare } from './support/Compare';

// Global CSS can't differ between two panes of one page, so CSS-only fixes are shown with
// headless-Chrome captures of the development preview: Before = without the PR, After = with it.
const meta: Meta = { title: 'Second pass/Theme and layout' };
export default meta;
type Story = StoryObj;

const Shot = ({ src, alt, note }: { src: string; alt: string; note?: string }) => (
  <figure className="sb-shot">
    <img src={src} alt={alt} />
    {note && <figcaption>{note}</figcaption>}
  </figure>
);
const pair = (name: string, alt: string, before?: string, after?: string) => ({
  before: <Shot src={`evidence/${name}-before.png`} alt={`${alt}, before`} note={before} />,
  after: <Shot src={`evidence/${name}-after.png`} alt={`${alt}, after`} note={after} />,
});

export const ScheduleLight: Story = {
  name: '#1470 Selected schedule days, light theme',
  render: () => (
    <Compare
      pr={1470}
      title="Selected weekdays were dark text on bright blue in light theme"
      wrong={
        <p>
          Selected days (and all text selection) used the theme's primary text color on the fixed
          brand blue. In light theme that's near-black on blue: <b>2.74:1</b>.
        </p>
      }
      fixed={<p>White text on the brand blue, as primary buttons already do: <b>6.53:1</b>.</p>}
      {...pair('schedule-light', 'Weekly schedule day chips in light theme', '2.74:1', '6.53:1')}
    />
  ),
};

export const FanStatusDark: Story = {
  name: '#1470 Home fan status, dark theme',
  render: () => (
    <Compare
      pr={1470}
      title="“Auto fan on” was dark blue on a dark panel"
      wrong={<p>The fixed brand blue on the dark card: <b>2.79:1</b>.</p>}
      fixed={<p>The theme-aware accent: <b>8.16:1</b>. The heat warning also gets a darker shade in light theme.</p>}
      {...pair('fan-status-dark', 'Home fan status in dark theme', '2.79:1', '8.16:1')}
    />
  ),
};

export const SliderDark: Story = {
  name: '#1470 Fan-speed slider, dark theme',
  render: () => (
    <Compare
      pr={1470}
      title="The fan-speed slider had a glaring white track in dark theme"
      wrong={<p>A dark accent color made Chromium draw the unfilled track near-white.</p>}
      fixed={<p>The theme-aware accent keeps the track dark.</p>}
      {...pair('slider-dark', 'Cooling fan-speed slider in dark theme')}
    />
  ),
};

export const SwitchLight: Story = {
  name: '#1470 Off switches, light theme',
  render: () => (
    <Compare
      pr={1470}
      title="Off switches nearly disappeared on white"
      wrong={<p>The off track was 18% black on white (~1.5:1).</p>}
      fixed={<p>A heavier track in light theme.</p>}
      {...pair('switch-light', 'An off switch in light theme')}
    />
  ),
};

export const TabsFocus: Story = {
  name: '#1470 Focus ring on My Macs tabs',
  render: () => (
    <Compare
      pr={1470}
      title="Keyboard focus rings were clipped on the My Macs tabs"
      wrong={
        <p>
          The tab strip scrolls horizontally, which clips the focus ring drawn 4 px outside the
          button: only its right edge showed on “Overview”. Home's Mac rows had the same problem.
        </p>
      }
      fixed={<p>The ring is drawn inside the control; the labels don't move.</p>}
      before={<Shot src="evidence/tabs-focus-before.png" alt="My Macs tabs with Overview focused, before" />}
      after={<Shot src="evidence/tabs-focus-after.png" alt="My Macs tabs with Overview focused, after" />}
    />
  ),
};

export const Earnings30d: Story = {
  name: '#1475 30-day earnings bars at 1024 px',
  render: () => (
    <Compare
      pr={1475}
      title="30-day earnings bars were hairline-thin"
      wrong={
        <p>
          Each bar is a button that kept the browser's default padding (1px 6px), leaving a{' '}
          <b>4.7 px</b> bar in a 16.7 px slot.
        </p>
      }
      fixed={<p>No padding on the bar buttons: <b>16.7 px</b> bars; spacing comes from the grid gap.</p>}
      {...pair('earnings-30d', 'Earnings 30-day bars at 1024 by 700')}
      stack
    />
  ),
};

export const ActivityNarrow: Story = {
  name: '#1475 Activity table at the minimum window width',
  render: () => (
    <Compare
      pr={1475}
      title="The Activity table hid its Earned column at 940 px"
      wrong={
        <p>
          The table's 760 px minimum exceeded its 698 px container, so <b>Earned</b> sat
          off-screen behind an invisible macOS overlay scrollbar.
        </p>
      }
      fixed={<p>A 640 px minimum fits the narrowest window; every column is visible.</p>}
      {...pair('activity-940', 'Stats Activity table at 940 by 650')}
    />
  ),
};

export const MenuBarIcon: Story = {
  name: '#1480 Menu bar icon size and sharpness',
  render: () => (
    <Compare
      pr={1480}
      title="The menu bar icon was too big and blurry"
      wrong={
        <p>
          The tray image was a single 19×22 px bitmap: as tall as the whole menu bar, and with no
          Retina version macOS upscaled it, so it looked bigger and softer than its neighbors.
        </p>
      }
      fixed={
        <p>
          A 16 pt mark rendered from the vector at 1× and 2× (<code>trayTemplate@2x.png</code>).
          Composited at Retina scale: top row before, bottom row after.
        </p>
      }
      before={<Shot src="evidence/menubar-before-after.png" alt="Menu bar at Retina scale: old icon (top) and new icon (bottom)" />}
      after={
        <p className="sb-observed">
          New icon: 16×16 pt (32×32 px at 2×), glyph 14×16 pt, black-and-alpha template, matching
          neighboring menu bar icons. See the bottom row on the left.
        </p>
      }
    />
  ),
};
