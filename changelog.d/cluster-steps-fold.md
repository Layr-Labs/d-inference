### The cluster screen folds each finished step to one line

- In a color terminal, `darkbloom cluster` (and the screen that `start`, `stop`, `restart` and `update` open on a paired
  Mac) now folds each step to one line once the next one begins, for example "✓ 2/4 Pair (1 min 12 s)". The screen
  no longer runs down with a line for every update.
- The lines that stay are the pairing code, each question with the answer you gave, any ✗ with its next steps, and the
  final outcome. A step taller than the window stays as it was.
- Nothing is lost: each run's whole flow, line by line, goes to a log file in `~/.darkbloom/cluster-setup/screens/`.
  Its path is the last line ("Full log: …"), and a ✗ names it too.
- Plain output (pipes, logs, `NO_COLOR`, `TERM=dumb`) doesn't change.
