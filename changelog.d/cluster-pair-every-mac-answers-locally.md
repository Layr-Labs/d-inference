### Every Mac of a pair answers locally in Both, me first

- With **Both, me first**, every Mac of the pair now has its own local API address, as with `darkbloom cluster local`:
  each Mac that doesn't run the pair's API passes its own port to it over the cable. `darkbloom local` there prints
  `http://127.0.0.1:<port>/v1` and the key to use, `darkbloom status` names that address, the setup's ✓ block says the
  local API is on that Mac, and `darkbloom start --opencode` or `--hermes` there sets the tools up for it.
- Each Mac's tools use that Mac's own key (`local_token`), in both ways a pair serves locally. The pair's API takes
  its own Mac's key and the pair's key (`cluster_local_token`), which tools set up before keep working with; the other
  Mac's port passes requests on with the pair's key.
- The port is the pair API's own when it is free on that Mac, else the first free one from 8001, never 8000 or the
  pair ports 47420–47423. With the pair's API kept on its own Mac (`--bind` loopback or one address), nothing changes.
- A request on the other Mac's port pauses Darkbloom for the pair, as one on the leading Mac does, and never uses the
  paid network: the pair's API sees it come from that Mac.
- `darkbloom start --opencode` on a paired Mac waits up to 30 seconds for that Mac's local API after the pair starts,
  and says at once when the pair serves only the Darkbloom network.
