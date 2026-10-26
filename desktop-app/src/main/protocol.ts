import { net, protocol } from 'electron';
import { pathToFileURL } from 'node:url';
import { contentSecurityPolicy, rendererFile } from './security';

// Must run before the app is ready.
export function registerAppScheme() {
  protocol.registerSchemesAsPrivileged([
    { scheme: 'darkbloom', privileges: { standard: true, secure: true, supportFetchAPI: true } },
  ]);
}

// Serves the bundled renderer from darkbloom://app/ with a strict CSP.
export function serveRenderer(root: string) {
  protocol.handle('darkbloom', (request) => {
    const file = rendererFile(root, request.url);
    if (!file) return new Response('Forbidden', { status: 403 });
    return net.fetch(pathToFileURL(file).toString()).then((response) => {
      const headers = new Headers(response.headers);
      headers.set('Content-Security-Policy', contentSecurityPolicy);
      return new Response(response.body, { status: response.status, headers });
    });
  });
}
