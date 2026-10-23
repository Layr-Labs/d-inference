import type { Snapshot } from '../shared/contracts';

// Development preview only. `?preview&account=unlinked` starts without a linked account so
// linking can be walked through; the browser approval arrives a few seconds after the code
// is shown.
const params = new URLSearchParams(globalThis.location?.search);
const approvalMs = 6000;

export const withPreviewAccount = (snapshot: Snapshot): Snapshot =>
  params.get('account') === 'unlinked' ? { ...snapshot, linked: false } : snapshot;

export function previewLink(
  snapshot: Snapshot,
  publish: (update: (snapshot: Snapshot) => Snapshot) => void,
): Snapshot {
  if (snapshot.linked) return snapshot;
  setTimeout(
    () => publish((current) => ({ ...current, linked: true, link: undefined })),
    approvalMs,
  );
  return {
    ...snapshot,
    link: {
      url: 'https://darkbloom.dev/link',
      code: 'KXQF-7M2P',
      expires_at: Date.now() / 1000 + 900,
      state: 'pending',
    },
  };
}
