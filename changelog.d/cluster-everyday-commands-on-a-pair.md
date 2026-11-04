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
- The DevNet app names `darkbloom-dev` in every command it suggests for a pair: the card after `start` and
  `restart`, `cluster stop --service`, `cluster local`, `cluster pair --forget` and the hints. Its Local Network hint
  names the app to allow, Darkbloom Dev.
- `stop`, `restart`, `cluster stop --service` and a script `start` say what they are waiting for and for how long at
  most, instead of going quiet for minutes.
- With Darkbloom and Darkbloom Dev on one Mac, each lists only its own cluster incidents. Incidents recorded before
  this count as Darkbloom's.
- The leading Mac's service log notes the other Mac's status checks once a minute, not every second.
- Darkbloom Dev keeps its cluster incidents in a file of its own, so Darkbloom never lists them, even before
  Darkbloom itself updates.
- Right after Darkbloom Dev is installed on a paired Mac, `darkbloom-dev doctor` no longer fails with "Configuration
  input is unsafe, empty or oversized" before a cluster setup is chosen with it. A saved setup in a file that other
  users can open fails with the fix (`chmod 600 …`).
- In the DevNet app, `darkbloom-dev cluster` without a terminal, the "Cluster service" line of `status`, Ctrl-C in
  the setup screen and the pair update hints name `darkbloom-dev`.
- `darkbloom cluster status --json` on the leading Mac says whether the other Mac answers while they run the cluster.
- On the Mac that follows, `cluster status` and `status` wait at most 10 seconds for the leading Mac's answer, and say
  so when it is slow; past that they show this Mac's own view.
- `darkbloom unenroll` (leaving fully) and the app's local mode no longer stop with an internal error when they stop or
  drain the provider first.
- `status` and `cluster status` no longer say "loading" while macOS keeps a Mac off the local network: both Macs say
  the pair is not serving and what to turn on, on which Mac. A stopped pair reads stopped even when the other Mac has
  gone.
- On the leading Mac, that "not serving" now holds while the other Mac stays refused, also while the leading Mac's
  part restarts; `cluster status --json` then lists the same "Not serving" line as the plain output. The DevNet app's
  stopped pair names its own `local` command.
- `cluster status --json` gives the serving mode and each Mac's share, and the "Model:" line of `status` and `cluster
  status` names the mode, for every mode. Before, a pair serving GLM-5.3-Flash in pipeline left them out.
