### `darkbloom route this-mac`, `my-macs` or `my-macs-first`

- `darkbloom route this-mac`, `darkbloom route my-macs` and `darkbloom route my-macs-first` save where your requests go when this Mac's local API can't take them (`[local] route`), so the route no longer needs a hand edit of `provider.toml` or a whole `darkbloom start --route`. Each says what it means: `my-macs` sends them to your other Macs, free, and never to the network; `my-macs-first` sends them to your other Macs, then to the Darkbloom network, billed, and requests from other machines (your LAN or tailnet) never use the paid network.
- `my-macs` and `my-macs-first` need your account API key: without one they save nothing, exit 1 and name `darkbloom route key`. They only ask whether a key is saved; no line shows a key.
- A local API running now keeps its route until it starts again, and the command names `darkbloom restart`. On the Mac that follows in a two-Mac cluster, it says the pair's route is the leading Mac's.
- `darkbloom route key`, with `[local] route = "this-mac"`, now names `darkbloom route my-macs` to use the key.
