### `darkbloom status` shows the answers in progress

- Under the serving block, `darkbloom status` lists each answer the Mac is
  writing: the model, how long it has run, output tokens so far, its current
  tokens per second and a short hash of its request (never the prompt, the
  answer or the request ID), then "Credits post when a paid answer finishes;
  requests to your own machine are free." A Mac writing two long answers no
  longer looks hung while its served and token counters wait for them to
  finish. The engine's own calibration and warmup probes are not listed. On a
  two-Mac cluster the leading Mac lists the pair's answers under the pair.
  `darkbloom status --json` prints the same list as JSON.
- The daemon reads them from counters its engines already keep, once per
  state-file write (about every 2 s), into `running_requests` in its state
  file. Nemotron Super's answers are not listed yet.
