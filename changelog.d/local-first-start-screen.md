### One start screen: only me, the Darkbloom network, or both with me first

- In a terminal, the first `darkbloom start` asks how this Mac serves: **Only me, on this Mac**, **Darkbloom
  network**, or **Both, me first** (pre-selected: Darkbloom pauses while you use this Mac and comes back after 2 idle
  minutes). With an account key saved, it also asks where your requests go when this Mac can't take them. The answer
  is saved in `[local]` once the start goes ahead; later starts don't ask again, and `darkbloom start --choose` asks
  again. See [Use your Mac yourself, first](docs/provider/local-first.md).
- Starts without a terminal (the login service, the app, scripts) never ask. Without a saved choice, a plain start
  keeps today's behaviour exactly: the Darkbloom network, no local port, nothing written. **Changed:**
  `--local-endpoint`, which the desktop app's "Alongside the network" passes, now pauses Darkbloom while you use the
  local API (below).
- A saved **Only me** serves in a terminal. A start without one, such as the app's Start, is refused in one line
  before anything stops or starts, naming `--local`, `--network` and `--me-first`.
- New flags, for one start: `--network`, `--me-first`; saved settings: `--no-me-first`, `--me-first-idle <min>`,
  `--route this-mac|my-macs|my-macs-first`. Contradicting flags such as `--local --me-first` are refused before
  anything runs. On a paired Mac they need `--solo`, like the other single-Mac options.
- **Changed:** `--local-endpoint` now means Both, me first: Darkbloom pauses while you use the local API.
  `--local-endpoint --no-me-first` keeps the old shared serving. Its LaunchAgent arguments are unchanged.
- A new local API takes the first free port from 8000 up, never 8000 itself (other local AI apps use it) or the
  pair ports 47420–47423, saves it and says which; `--port` still picks one.
- `darkbloom status` says how this Mac serves in one line (for example `Serving: you first — Darkbloom paused since
  14:02 …`) and where your requests go, with whether an account key is saved. `darkbloom local` adds the same, and
  names `start --me-first` beside `start --local`. With `--no-auth`, `start` and `status` say your requests stay on
  this Mac. No start screen prints the local key (except `--local`'s own banner, as before), and no screen shows a
  speed.
