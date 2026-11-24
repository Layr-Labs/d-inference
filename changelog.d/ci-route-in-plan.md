### Provider CI: the plan job routes the run

- CI's route request is the last step of the plan job (`Plan the components to test`) instead of a job of its own, so the macOS jobs wait for one GitHub-hosted job instead of two. On 2026-11-23 and 2026-11-24 the separate route job put a median 7 s (90th percentile 8 s, 102 runs) from the plan job's end to the first routed job's creation; with the step, about 2 s remain (model).
- The step runs the route workflow's own script, byte for byte, with its environment: the same request, retries, fallbacks and log. Every lane keeps its count, size and fallback; the step keeps the route job's 3-minute bound and runs after any earlier failure unless the run is cancelled.
- A CI run no longer has a `plan / route / Select Runners` job. The GitHub-side watchdog therefore re-runs a stranded CI run whole, and the new attempt's plan routes again.
