import type { Meta, StoryObj } from '@storybook/react-vite';
import AppBefore from '../src/before/desktop-app/src/renderer/App';
import AppAfter from '../src/after/desktop-app/src/renderer/App';
import { previewAPI } from '../src/after/desktop-app/src/renderer/preview';
import { resetBridges } from './support/bridge';

// The whole desktop app from each version, fed by the app's own development-preview fixtures.
// Used full-page by the scroll story, which needs a document of its own per version.
const meta: Meta = {
  title: 'Internal/Full app',
  parameters: { layout: 'fullscreen' },
  beforeEach: () => {
    localStorage.setItem('darkbloom.onboardingComplete', '1');
    resetBridges({ read: (resource) => previewAPI.read(resource as never) });
  },
};
export default meta;
type Story = StoryObj;

export const Before: Story = { render: () => <AppBefore /> };
export const After: Story = { render: () => <AppAfter /> };
