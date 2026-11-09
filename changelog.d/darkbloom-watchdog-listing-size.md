### Darkbloom watchdog reads any listing size and rescues partial strands

- `.github/workflows/darkbloom-watchdog.yml` is now darkbloom-sandbox's template at `d6d257c2`, copied unchanged. The old copy passed the day's run and job listings to `jq` as command-line arguments. When the repository was busy they were larger than Linux allows for one argument, and the watchdog failed with `Argument list too long` (exit 126) before it checked any run. It now passes listings to `jq` through files and stdin.
- A job's wait is timed from its own creation. Only a Darkbloom job of the run that got a runner within the wait holds the rescue back, so a run with one shard stranded while other shards ran is rescued too.
- The watchdog sees only GitHub: a job that waits at the payer's concurrency or resource limit looks stranded to it. Set `DARKBLOOM_WATCHDOG_MINUTES` above such waits. The repository variables are unchanged.
