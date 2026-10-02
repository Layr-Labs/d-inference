# Community tools for providers

> Last updated: 2026-10-02 · commit `4bc3a0a3b`

Reference list of third-party apps and scripts that some operators run beside
the `darkbloom` provider to monitor it or manage its models. None of them is
made, reviewed, endorsed or supported by Darkbloom; each is maintained by its
author, may lag provider releases, and runs at your own risk. Run only one tool
that starts, stops, restarts or switches the provider's models at a time.

## Tools

Listed alphabetically. Descriptions and licenses come from each tool's own
repository; "Controls the provider" means the tool's README says it can start,
stop, restart or switch models on the provider, whether by default or as an
option.

| Tool | Maintainer | Runs as | What it does | Controls the provider | License |
|---|---|---|---|---|---|
| [BloomGauge](https://github.com/cookder/bloomgauge) | [cookder](https://github.com/cookder) | macOS app with a local web dashboard | Shows earnings, network demand and hardware health; recovers stalls with a test request, then a restart; model optimizer, on by default after setup | Yes | MIT |
| [Bloomy](https://github.com/knightfolk/Bloomy) (formerly Darkbloom Control) | [knightfolk](https://github.com/knightfolk) | macOS menu bar app | Shows provider status, earnings and energy estimates; start, stop and restart controls; optional model switching, off by default; optional idle nudge (a small request routed to your own Mac) | Yes | None listed |
| [Darkbloom Dashboard](https://github.com/SplittyDev/darkbloom-dashboard) | [SplittyDev](https://github.com/SplittyDev) | macOS, iOS and visionOS app, built from source | Shows network health, machine and account statistics and local logs; warm-up and provider restart | Yes | MIT |
| [Darkbloom Live & Stats](https://github.com/jordglob/darkbloom-live-stats) | [jordglob](https://github.com/jordglob) | Local web dashboard with LaunchAgents | Shows hardware gauges, electricity cost against revenue and account payouts; keeps configured models warm | No | MIT |
| [darkbloom-manager](https://github.com/benbuschmann/darkbloom-manager) | [benbuschmann](https://github.com/benbuschmann) | Python command-line script | Scores downloaded models by network pressure and price and switches the warm model when the provider is idle | Yes | MIT |
| [Darkbloom Monitor](https://github.com/justin-schroeder/darkbloom-monitor) | [justin-schroeder](https://github.com/justin-schroeder) | macOS menu bar app | Shows provider status, earnings, hardware metrics and hourly charts; start, stop and restart controls | Yes | None listed |

## How to add a tool

Open a pull request that adds one row to the table above, in alphabetical
order. A listed tool has a public source repository and works with the current
provider release.

## Related

- [`cli-reference.md`](./cli-reference.md) — `darkbloom switch`, `stop` and `restart`, the provider commands behind model switching and restarts
- [`quickstart.md`](./quickstart.md) — set up the provider these tools run beside
- [`troubleshooting.md`](./troubleshooting.md) — symptom → check → fix for the provider itself
