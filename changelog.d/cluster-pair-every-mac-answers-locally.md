### Every Mac of a pair answers locally in Both, me first

- With **Both, me first**, every Mac of the pair now has its own local API address, as with **Only me**
  (`darkbloom cluster local`), not only the Mac that runs the pair's API: each other Mac passes its own port to it over
  the cable. `darkbloom local` there prints `http://127.0.0.1:<port>/v1` and the key to use, `darkbloom status` names
  that address instead of pointing at the leading Mac, the setup's ✓ block prints this Mac's own address once its port
  is up, and `darkbloom start --opencode` or `--hermes` there sets the tools up for it.
- Each Mac's tools use that Mac's own key (`local_token`), with **Only me** and with **Both, me first**. The pair's API
  takes its own Mac's key and the pair's key (`cluster_local_token`), which tools set up before keep working with; the
  other Mac's port passes requests on with the pair's key.
- A pair's local API now takes each Mac's own saved `[local] port`, as every other local API on that Mac does, with
  **Only me** and with **Both, me first**: the Mac that runs the pair's API listens on its port, and each other Mac's
  port passes requests to it, so the ports can differ, and each Mac keeps its own whichever Mac runs the pair's API.
  Before, the pair's API took a port free on both Macs (Only me 8000 when free) and the other Mac took the same one. A
  Mac with no saved port keeps the one its local API already uses, else takes the first free one from 8001, never 8000
  or the pair ports 47420–47423, and saves it; a Mac updated from 0.10.10 keeps 8000. With the pair's API kept on its
  own Mac (`--bind` loopback or one address), the other Mac passes nothing on, as before.
- A saved port is never moved, a pair's included: when another program holds it, `darkbloom status` on that Mac names
  the port and says to free it, or set another `[local] port` in `provider.toml`, then run `darkbloom restart`. For the
  pair's API this replaces "`darkbloom restart` starts the pair's API on a free port".
- While Darkbloom doesn't have a **Both, me first** pair (no approval yet), the pair answers on the leading Mac only,
  and the other Mac passes nothing on: its `darkbloom status` says so, and never shows an address that resets every
  connection.
- While the Mac that runs the pair's API is away (unplugged, asleep), the other Mac's own port answers every request at
  once with a `503` (`code` `pair_mac_unreachable`) that says so: "Your pair's other Mac (…) isn't reachable; this Mac
  relays to it. Requests resume when it's back, or run `darkbloom stop`, then `darkbloom start --solo`, to serve this
  Mac alone." That Mac counts as away once it hasn't answered over the cable for 12 seconds. Only a request with this
  Mac's key or the pair's gets those words; any other gets the local API's usual `401`, or a `503` without names where
  the API needs no key. With **Only me**, that port used to close each connection unanswered then, for up to 15 minutes.
  `darkbloom status` and `darkbloom local` now say the same, and relaying resumes by itself within seconds of that Mac
  answering again. A request while that Mac's API doesn't listen gets a `503` with `code` `pair_api_unavailable`.
- On the other Mac, `darkbloom local` and `darkbloom start --opencode` say why it has no address for the pair (Darkbloom
  doesn't have the pair yet, its port is held, or the leading Mac is away), as `darkbloom status` does: `local` no
  longer prints the pair's key there, and `--opencode` says it at once instead of after a 30-second wait. While that
  address is still starting, `local` says so beside the pair's key, instead of "No local server running."
- The app's **Start serving** on the other Mac no longer says "No local API was added on this Mac" when the pair's API
  is on every address: that Mac's relay gives it one. While the relay can't answer (the leading Mac away, Darkbloom not
  having the pair, its port held), the app says `status`'s `Local API:` line instead. With the pair's API kept on the
  leading Mac, **Only me** included, the line stands.
- The solo server a pair falls back to when one Mac is away for 10 minutes takes that Mac's own saved `[local] port`
  too, instead of 8000, so its tools keep their address.
- A request on the other Mac's port pauses Darkbloom for the pair, as one on the leading Mac does, and never uses the
  paid network: the pair's API sees it come from that Mac.
- `darkbloom start --opencode` on a paired Mac waits up to 30 seconds for that Mac's local API after the pair starts,
  and says at once when the pair serves only the Darkbloom network.
