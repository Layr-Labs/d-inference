# Cluster console checks

Run `bash provider-swift/Tests/ClusterConsoleChecks/run.sh` from any directory.
The runner compiles the console sources under
`Sources/ProviderCore/Inference/Distributed/Console` with the cluster library
modules, the configuration, installed-session and link sources they read, and
the installed-session fixtures, using Swift 6 and warnings as errors, without
SwiftPM or MLX. It takes under a minute.

One console source is not built here: `ClusterConsoleLiveOperations.swift`
needs the whole provider (the doctor, the provider configuration reader, the
local endpoint token). It and the `darkbloom cluster console` command are
compiled and parsed by the full Provider suite
(`DarkbloomCLITests/ClusterConsoleCommandTests.swift`).

Checks cover:

- `handoff/TUI-wiring.md` against `ClusterConsoleWiring`: the same elements in
  the same three states, so nothing can be shown as live without a wired row.
- The key decoder: printable keys, control keys, arrow and paging sequences in
  both terminal modes, sequences split across reads, a lone escape byte, every
  single byte value, overlong and unknown sequences, non-ASCII input and an
  arbitrary stream cut at arbitrary points.
- The reducer with no terminal and no thread: refresh and queued refresh, the
  two polls and when each runs, the one automatic link fix and everything that
  spends it, each action's gating and result, one action at a time, approval
  only by `a` then `y` (including three thousand other keys), the session's
  states, and every way of leaving.
- The renderer at twenty-one sizes from 0x0 to 1000x1000 and at every scroll
  position: never more lines than rows, never a line wider than the columns,
  no control character, and exactly the bytes of one frame. Text from a file or
  a child process cannot draw on the screen.
- What each section says for each observed state, including that a load shows
  no percentage, that a dry run never claims a prompt is open, and that the
  plain output is the same state without keys.
- Redaction: fixtures holding IPv4, IPv6 and MAC addresses, host names, user
  names, home-directory paths, serial numbers, a hardware UUID, a private key,
  a public key, a fingerprint, bearer and local tokens and credential fields,
  each alone and together; none survives, redaction is stable when repeated,
  and digests, times, device names and versions are kept.
- The export: built from a real fixture setup whose files name a host, a user,
  an address and paths; the written file is owner-only, never replaces an
  existing one, parses as JSON and passes the redactor's own residue check.
- The saved-setup, trust, installed-file and candidate readers on real files
  under the scratch directory; approval through the store's own save.
- The link fix dry run over scripted tool text: the same plan and the same
  stops as the real fix, the prompt's sentence, no address, no record written;
  and the alias record read without clearing it.
- Recovery results for an empty journal, a live owner and a stranded journal.
- The terminal mode on a real pseudo-terminal: what `enter` sets, that `leave`
  restores exactly what was found, twice, and when the object is dropped.
- The run loop on a real pseudo-terminal: frames, help, a split arrow sequence
  against a lone escape, meaningless and pasted input, an action end to end,
  and the wait for a cable ending when the link changes.
- Resize: the window size is changed on the master end and SIGWINCH is sent to
  the process, down to 1x1 and 0x0 and up to 500x200, then in a burst.
- Cancellation: `q`, Ctrl-C, Ctrl-D, SIGTERM, SIGINT, SIGHUP, a write that
  fails (a thrown error), a terminal that goes away, and closing while an
  action is in flight; the terminal mode and the signal dispositions are
  restored on every one.
- Re-entrancy: action keys while an action is out, a burst of refresh keys
  while a refresh is out, and a second screen while one holds the lock (from
  this process and from another).
- The session process against `/bin/sh` children: live output, exit status,
  the interrupt, a child that ignores it (nothing stronger follows), a
  signalled end, long lines.
- Start and stop through the console against the real installed session with
  the fabricated owner and worker children (`StandIn/ConsoleSessionStandIn.swift`):
  per-rank readiness from the session's own status through the strict status
  reader, a cooperative stop, a clean exit and no process left behind.

Terminals in these checks are pseudo-terminals opened by the check itself; the
console runs on the slave end as it runs in a terminal window. The kernel
sends SIGWINCH only to a terminal's own foreground process group, which an
in-process console is not, so the resize check sends the signal itself after
changing the size. Operations are scripted except where a group says
otherwise. No RDMA or network tool, `osascript` or approval prompt is started,
no setting is read or changed, no model is loaded, no peer is contacted, and
nothing outside the runner's temporary directory is written. These checks do
not qualify `darkbloom start --local --distributed`, a second Mac, the local
HTTP server or the status endpoint.
