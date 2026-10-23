// The app's test fixtures build backends with vi.fn(); Storybook's spies are compatible.
import { fn } from 'storybook/test';
export const vi = { fn };
