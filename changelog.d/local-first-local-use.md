### Your own requests pause Darkbloom on your Mac

- With the local API beside Darkbloom (`darkbloom start --local-endpoint`), the Mac stops taking Darkbloom requests
  while one of your requests uses a model on it, and takes them again once none of your requests has run for 2 minutes
  (`[local] me_first_idle_minutes`, 1 to 120). Before, your requests and Darkbloom's shared the Mac.
- **This starts with this update on every Mac already serving with `--local-endpoint`**, including the desktop app's
  "Alongside the network": it pauses Darkbloom while you use its local API. Darkbloom requests already running finish.
- To keep sharing the Mac, set `me_first = false` under `[local]` in `provider.toml`
  (`~/.config/darkbloom/provider.toml`), then restart serving (`darkbloom restart`).
- Listing models, health checks, `/metrics` and the tokenizer utilities don't count, and neither do requests refused
  before they hold a model (a model the Mac doesn't serve, a load that doesn't fit, a drain).
- `darkbloom start --local` never connects to Darkbloom, so it has nothing to pause.
