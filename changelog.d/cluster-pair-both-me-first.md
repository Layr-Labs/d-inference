### Both, me first for a pair, in `darkbloom cluster`

- In a terminal, `darkbloom cluster` now asks how a pair serves, with the single-Mac start's three choices: **Only me
  (this pair, local)**, which is `darkbloom cluster local`'s way, **Darkbloom network**, or **Both, me first**, which
  is preselected. On a set-up pair, the list's **Change how the pair serves** asks again. The answer is saved in
  `[local] mode` once the start goes ahead. `darkbloom cluster local` is unchanged and asks nothing.
- With **Both, me first**, the Mac that runs the pair's first part also runs the pair's local API beside Darkbloom,
  with the pair's key, on every network of that Mac. Its port is the first one from 8001 to 8020 free on both Macs,
  never 8000 or the pair ports 47420–47423. Darkbloom pauses for the whole pair while you use it and comes back 2
  minutes after your last request. The other Macs run no local API.
- Without a terminal nothing is asked or saved. The login service and scripts keep serving each pair as its setup
  says, and a pair set up before this build serves through Darkbloom with no local API, as before.
- The question says that the pair's pause, route and account key are the leading Mac's. **Serve locally only** at the
  login check after **Both, me first** saves no answer: the pair serves locally only, and **Only me** isn't saved.
- `darkbloom status` and `darkbloom cluster status` say whether Darkbloom is paused for you, the pair's local address
  (never its key), and that the other Macs are part of the pair. On the other Mac they say that `darkbloom local` on
  the leading Mac shows the address and key. No line shows a speed.
- `darkbloom start --cluster-member` takes `--local-endpoint --port --bind` from the cluster service, never with
  `--no-auth`.
- A pair's local API without a cluster approval (its leader registered with the coordinator, or serving locally because
  the coordinator couldn't take it) no longer asks the coordinator whether your other Macs serve a model before passing
  your request on to them, as `cluster local` already didn't. The coordinator's count never includes that leader, so
  with exactly one other Mac serving the model the request was refused as `this_mac_only` instead of going to that Mac.
- With **Only me** saved, by `darkbloom cluster` for the pair or by `darkbloom start`, a start without a terminal (the
  app's Start, a script) on a Mac whose pair doesn't run here is refused in one line, as on one Mac. This Mac's part of
  the pair keeps running, and its saved start stays.
