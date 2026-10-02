import path from 'node:path';

// Every trust decision the main process makes about renderer input, in one
// electron-free module so it can be audited and unit tested.

export const appOrigin = 'darkbloom://app/';

export const contentSecurityPolicy =
  "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-src 'none'";

export interface IPCSender {
  sender: { mainFrame: unknown };
  senderFrame?: { url: string } | null;
}

// IPC is accepted only from the main frame of our own window, loaded from the
// packaged app origin (or the explicit development URL's origin).
export function isTrustedSender(event: IPCSender, window: unknown, devURL?: string) {
  const url = event.senderFrame?.url;
  return !(
    event.sender !== window ||
    event.senderFrame !== event.sender.mainFrame ||
    !url ||
    !(devURL
      ? new URL(url).origin === new URL(devURL).origin
      : new URL(url).protocol === 'darkbloom:' && new URL(url).hostname === 'app')
  );
}

export function allowedNavigation(url: string, devURL?: string) {
  return url.startsWith(devURL || appOrigin);
}

// Maps a darkbloom:// request to a file under the renderer root, or undefined
// for another host or any path that escapes the root.
export function rendererFile(root: string, requestURL: string) {
  const url = new URL(requestURL);
  const file = path.resolve(root, '.' + decodeURIComponent(url.pathname));
  if (url.host !== 'app' || !file.startsWith(root + path.sep)) return undefined;
  return file;
}

const links: Record<string, string> = {
  console: 'https://console.darkbloom.dev',
  docs: 'https://docs.darkbloom.dev',
  community: 'https://github.com/Layr-Labs/d-inference/discussions',
  terms: 'https://www.darkbloom.ai/terms',
  privacy: 'https://www.darkbloom.ai/privacy',
};
const linkHosts = ['console.darkbloom.dev', 'docs.darkbloom.dev', 'www.darkbloom.ai', 'github.com'];

// Resolves a renderer link target to an https URL on an allowlisted host.
// `link` is the device-link URL from the native backend's snapshot.
export function externalURL(target: unknown, deviceLinkURL: string | undefined) {
  const url =
    target === 'link'
      ? deviceLinkURL
      : typeof target === 'string' && Object.hasOwn(links, target)
        ? links[target]
        : undefined;
  if (!url || new URL(url).protocol !== 'https:' || !linkHosts.includes(new URL(url).hostname))
    throw new Error('Unsupported link');
  return url;
}

export function clipboardText(text: unknown) {
  if (typeof text !== 'string' || text.length > 65536) throw new Error('Invalid clipboard value');
  return text;
}
