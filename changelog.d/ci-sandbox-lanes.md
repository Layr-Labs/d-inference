### Provider CI: fewer Mac jobs per run, loose build-cache restores, macOS lane cap

- Provider Unit Tests runs in 2 shards instead of 3. Each shard builds once and runs 3 test selections at the same time, each serially in its own process with its own `TMPDIR` and provider state files. The isolated processes and the native gates still run after them, alone. The plan, the `KEPT_APART` pair and the Summary audit are unchanged; the audit now counts 6 selections.
- Cluster Runtime Tests runs in 2 shards instead of 3. Shard 1 runs the `base` selection alone. Shard 2 runs two groups at the same time, each in plan order: the batch-session suite with the GLM paged-KV, invariance and census, TF32 and Gemma selections; and the Qwen GPU chain with `glm53-prefix-ssd`. The share probe then runs alone, after `qwen-tp-batch-gpu`.
- Cluster GPU Tests (report only) run on pushes, not on pull requests.
- A cluster pull request now runs 7 Mac jobs instead of 11; a provider-only pull request runs 3 instead of 4.
- Pushes to `dev` share one concurrency group: one run in progress and the newest push waiting, instead of one run per push. A `dev` push run therefore runs every component, as a `master` push does.
- The Swift build cache restores from a loose tier that ignores the CI recipe, so a workflow or CI script edit no longer makes every build cold. A build that fails over a loose-tier entry builds once more from nothing. On Darkbloom hosts a push saves at most one build per lane and day.
- The MiMo metadata downloads are cached by their pinned SHA-256 and used only when their bytes match.
- The repository variable `DARKBLOOM_MACOS_LANES` caps the macOS jobs one run asks Darkbloom for; the rest use Blacksmith at once.
