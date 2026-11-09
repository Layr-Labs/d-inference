// How this Mac serves (local-first): Only me, the Darkbloom network, or Both, me first; where
// your requests go when this Mac's local API can't take them; and tools set up to use it
// (docs/provider/cli-reference.md#how-this-mac-serves-one-question).

// `[local] mode`: `local` (Only me), `network` (Darkbloom network, no local API) or `both` (Both,
// me first: a local API beside Darkbloom).
export type ServingMode = 'local' | 'network' | 'both';
// How a `start` asks for each way to serve (`--local`, `--network`, `--local-endpoint`). The start
// saves it as `[local] mode` once it goes ahead, and later starts serve it.
export const startFlags: Record<ServingMode, { local?: true; network?: true; endpoint?: true }> = {
  local: { local: true },
  network: { network: true },
  both: { endpoint: true },
};
// `[local] route`: where your requests go when this Mac's local API can't take them.
export type RequestRoute = 'this-mac' | 'my-macs' | 'my-macs-first';
// `darkbloom --opencode` / `--hermes`.
export type LocalTool = 'opencode' | 'hermes';

// `Snapshot.local`, from provider.toml's `[local]` section. Absent from older runtimes.
export interface LocalServing {
  // The saved choice. Null before the first choice.
  mode: ServingMode | null;
  // Both, me first: Darkbloom pauses while your local requests run, and for
  // `me_first_idle_minutes` after (1–120). False: Darkbloom keeps serving beside you.
  me_first: boolean;
  me_first_idle_minutes: number;
  // Where your requests go when this Mac's local API can't take them: the saved route, else the
  // one that applies (`LocalSettings.resolvedRoute`: only my Macs once an account key is saved,
  // else this Mac only). The app resolves a null the same way.
  route: RequestRoute | null;
  // An account API key is saved (`darkbloom route key`); the key itself never crosses.
  route_key: boolean;
  // This Mac's one local API port and bind address.
  port: number | null;
  bind: string | null;
  // Darkbloom is paused for you right now (Both, me first), until about this time (Unix s).
  paused_until?: number | null;
}

// The route that applies: the saved one, else only my Macs once an account key is saved, else
// this Mac only (`LocalSettings.resolvedRoute`).
export const effectiveRoute = (
  local: Partial<Pick<LocalServing, 'route' | 'route_key'>>,
): RequestRoute => local.route ?? (local.route_key ? 'my-macs' : 'this-mac');

export type LocalServingAction =
  // `darkbloom route this-mac|my-macs|my-macs-first`: saves `[local] route`.
  | { action: 'route'; route: RequestRoute }
  // `darkbloom route key`: saves the account API key, passed on standard input, never argv.
  | { action: 'route_key'; key: string }
  // Saves `[local] me_first` and `me_first_idle_minutes`.
  | { action: 'local_settings'; me_first: boolean; me_first_idle_minutes: number }
  // `darkbloom start --opencode` / `--hermes`: set the tool up to use this Mac's local API.
  | { action: 'tool_setup'; tool: LocalTool }
  // `darkbloom update --rollback`: return to the previous release.
  | { action: 'update_rollback' };
