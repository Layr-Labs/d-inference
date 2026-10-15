import { api } from './useBackend';

// Opens System Settings at Software Update. Nothing in the app depends on the result.
export function openSoftwareUpdate() {
  void api?.openSoftwareUpdate().catch(() => undefined);
}
