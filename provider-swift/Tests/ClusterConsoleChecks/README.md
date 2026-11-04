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
  the same three states, so nothing can be shown as live without a wired row;
  and the admitted-model listing against the adapter's registered pairs and
  against the adapter's source.
- The key decoder: printable keys, control keys, arrow and paging sequences in
  both terminal modes, sequences split across reads, a lone escape byte, every
  single byte value, overlong and unknown sequences, non-ASCII input, a
  bracketed paste (whole, split, unterminated) and an arbitrary stream cut at
  arbitrary points.
- The reducer with no terminal and no thread: refresh and queued refresh, the
  two polls and when each runs; the one automatic link fix, the wait it gives
  the system job first, and everything that spends it; each action's gating and
  result, one action at a time, and nothing that touches the link, the saved
  setup or the journal beside a session; approval only by `a`, a drawn
  question and `y` (including three thousand other keys, and three thousand
  keys with no frame drawn); questions that are not asked, or are withdrawn,
  where the window cannot show all of them; the session's states; and every
  way of leaving, with a session, an action, or both.
- The renderer at twenty-one sizes from 0x0 to 1000x1000 and at every scroll
  position: never more lines than rows, never a line wider than the columns,
  no control character, and exactly the bytes of one frame. Text from a file or
  a child process cannot draw on the screen. Every question fits 80 columns.
- What each section says for each observed state, including that a load shows
  no percentage, that a dry run never claims a prompt is open, what is said
  about an assigned address and the job that keeps it, and that the plain
  output is the same state without keys. Every line that states something
  names a wired row, and between them the lines and actions cover every wired
  row.
- Redaction: fixtures holding IPv4, IPv6 and MAC addresses in several
  spellings, host names, user names, whole and partial home-directory paths,
  serial numbers, a hardware UUID, a private key with and without its first
  line, a public key, a fingerprint, bearer and local tokens and credential
  fields, each alone and together; none survives, redaction is stable when
  repeated, and digests, times, device names and versions are kept. The second
  look that guards the export is exercised on its own.
- The export: built from a real fixture setup whose files name a host, a user,
  an address and paths; the written file is owner-only, never replaces an
  existing one, parses as JSON and holds none of them, with and without the
  identifiers known. The snapshot itself is checked to carry none before any
  export.
- The saved-setup, trust, installed-file and candidate readers on real files
  under the scratch directory; approval through the store's own save on a held
  copy, refused when the input changed after it was shown, and unaffected by
  the input being replaced while the save runs.
- The link fix through `ClusterLinkRepair.fix` over a scripted Mac: its dry
  run (the commands, no approval, no record), a ready link, a declined prompt,
  a prompt that cannot be shown, and an approved change that did not take,
  each as the console shows it; and the guided setup's reading of each link
  state, which decides what the screen does by itself.
- Recovery results for an empty journal, a live owner and a stranded journal.
- The terminal mode on a real pseudo-terminal: what `enter` sets, that `leave`
  restores exactly what was found, twice, and when the object is dropped; and
  a terminal that stops reading, where a write fails after its allowance and
  the mode still goes back.
- The run loop on a real pseudo-terminal: frames, help, a split arrow sequence
  against a lone escape, meaningless and pasted input, an action end to end,
  and the wait for a cable ending when the link changes.
- Resize: the window size is changed on the master end and SIGWINCH is sent to
  the process, down to 1x1 and 0x0 and up to 500x200, then in a burst; a
  question open when the window narrows is withdrawn and `y` then does nothing.
- Cancellation: `q`, Ctrl-C, Ctrl-D, SIGTERM, SIGINT, SIGHUP, a write that
  fails (a thrown error), a terminal that goes away, and closing while an
  action is in flight; the terminal mode and the signal dispositions are
  restored on every one. With a session running: `q` twice, SIGTERM, a
  vanished terminal and a thrown error each send it exactly one interrupt.
- Re-entrancy: action keys while an action is out, a burst of refresh keys
  while a refresh is out, keys that arrive in the same write as the key that
  asks, keys inside a question, action keys beside a running session, and a
  second screen while one holds the lock (from this process and from another).
- The session process against `/bin/sh` children: live output, exit status,
  the interrupt, a child that ignores it (nothing stronger follows), a
  signalled end, long lines in bounded pieces, carriage-return progress and
  empty lines.
- Start and stop through the console against the real installed session with
  the fabricated owner and worker children (`StandIn/ConsoleSessionStandIn.swift`):
  per-rank readiness and admission from the session's own status through the
  strict status reader, a cooperative stop, a clean exit and no process left
  behind.

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
