### On a Mac in a two-Mac cluster, the everyday commands control the pair

- `darkbloom stop`, `start`, `restart` and `status` now work on a paired Mac the way they work on one Mac, and each
  says first that it acts on the pair. `--solo` on any of them acts on single-Mac serving on this Mac only and never
  touches the pair.
- `darkbloom stop` (or `darkbloom cluster stop`) stops serving on both Macs, from either Mac. They stay stopped when
  a Mac restarts, and both Macs stay reachable, so `darkbloom start` on either Mac starts the pair again. It ends by
  checking that the memory was freed on both Macs. If the leading Mac doesn't answer, it says so and how to stop this
  Mac alone. The earlier `cluster stop`, which also turns this Mac's cluster service off, is
  `darkbloom cluster stop --service`.
- `darkbloom start` opens the same screen as `darkbloom cluster` in a terminal. In a script it starts the pair's saved
  model, waits until it serves, and ends with a short summary, as single-Mac start does; the exit status says whether
  it serves. Single-Mac options such as `--model` need `--solo` there; without it, `start` names them and
  starts nothing.
- `darkbloom restart` restarts the pair with its current model. `darkbloom status` starts with the pair: who leads,
  the model, whether it serves now and what to do.
- `darkbloom stop` no longer says "Provider service is not running" on a paired Mac, and never stops the cluster's own
  part when stopping single-Mac serving.
- `darkbloom cluster status` answers in plain words, with `--json` for scripts and agents and an exit status (0
  serving, 3 not serving yet, 4 stopped, 5 the other Mac isn't answering, 6 not in a cluster, 7 this Mac's pairing
  record can't be read). The earlier detailed report is `--details`.
- A Mac whose pairing record can't be read is never reported as "not in a cluster": the commands say so and how to
  check it (`darkbloom cluster`). `start`, `stop` and `restart` then change nothing without `--solo`.
- `darkbloom cluster --help` lists the other cluster commands and what each is for.
- `darkbloom cluster link --remove` on a paired Mac warns first that it undoes the working cable setup and stops the
  cluster on both Macs, and asks once (`--yes` for scripts).
- `darkbloom stop` says the pair stopped only once both Macs' parts have ended (it waits up to a minute); otherwise it
  says it asked both Macs and what is still running. A failed stop on the Mac that follows says what is known.
  `darkbloom restart` starts the pair again only once both parts have ended. A script `start` waits through the
  coordinator's pairing and an Apple verification retry instead of reporting "not serving".
- A cluster service left from an earlier pairing no longer makes a Mac count as paired; `darkbloom cluster status`
  names it and how to remove it. `--solo` refuses while this Mac's part of the pair serves (they share one serving
  lock). The app's local mode says plainly that it isn't available on a paired Mac.
- `darkbloom update --rollback`'s advice turns the cluster service off with `darkbloom cluster stop --service`.
