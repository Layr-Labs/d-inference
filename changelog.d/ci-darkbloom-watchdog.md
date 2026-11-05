### CI rescues runs stranded on Darkbloom

- A scheduled workflow, `darkbloom-watchdog.yml` (darkbloom-sandbox's GitHub-side watchdog, copied unchanged), cancels a run whose Darkbloom job waited `DARKBLOOM_WATCHDOG_MINUTES` with no runner and re-runs its route on the Blacksmith fallback, once per run. Its token can only cancel and re-run this repository's workflow runs and write a check run.
