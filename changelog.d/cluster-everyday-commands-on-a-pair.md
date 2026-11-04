### On a Mac in a two-Mac cluster, the everyday commands control the pair

- `darkbloom stop`, `start`, `restart` and `status` now work on a paired Mac the way they work on one Mac, and each
  says first that it acts on the pair. `--solo` on any of them acts on single-Mac serving on this Mac only and never
  touches the pair.
- `darkbloom stop` (or `darkbloom cluster stop`) stops serving on both Macs, from either Mac. They stay stopped after
  a restart, and both Macs stay reachable, so `darkbloom start` on either Mac starts the pair again. It ends by
  checking that the memory was freed on both Macs. If the leading Mac doesn't answer, it says so and how to stop this
  Mac alone. The earlier `cluster stop`, which also turns this Mac's cluster service off, is
  `darkbloom cluster stop --service`.
- `darkbloom start` opens the same screen as `darkbloom cluster` in a terminal. In a script it starts the pair's saved
  model, waits until it serves, and ends with a result block like single-Mac start's; the exit status says whether it
  serves.
- `darkbloom restart` restarts the pair with its current model. `darkbloom status` starts with the pair: who leads,
  the model, whether it serves now and what to do.
- `darkbloom stop` no longer says "Provider service is not running" on a paired Mac, and never stops the cluster's own
  part when stopping single-Mac serving.
- `darkbloom cluster status` answers in plain words, with `--json` for scripts and agents and an exit status (0
  serving, 3 not serving yet, 4 stopped, 5 the other Mac isn't answering, 6 not in a cluster, 7 this Mac's pairing
  record can't be read). The earlier detailed report is `--details`.
- A Mac whose pairing record can't be read is never reported as "not in a cluster": the commands say so and how to
  check it (`darkbloom cluster`), and act on single-Mac serving only with `--solo`.
- `darkbloom cluster --help` lists the other cluster commands and what each is for.
- `darkbloom cluster link --remove` on a paired Mac warns first that it undoes the working cable setup and stops the
  cluster on both Macs, and asks once (`--yes` for scripts).
