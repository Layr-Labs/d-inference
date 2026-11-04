### The everyday commands say the truth on a Mac in a two-Mac cluster

- `darkbloom stop` no longer says "Provider service is not running" while the pair serves, and never stops the
  cluster's part. It says the Mac is in a two-Mac cluster, names the other Mac, and points to
  `darkbloom cluster stop` (both Macs stop). Single-Mac serving, when there is some, is stopped as before.
- `darkbloom start` and `darkbloom restart` no longer start single-Mac serving beside a running cluster by accident:
  they say why and how to stop the cluster first, or take `--solo` to serve on this Mac too.
- `darkbloom status` and `darkbloom doctor` add one line about the pair (who leads, the other Mac, the model, whether
  it serves), and no longer tell a Mac in a cluster to run `darkbloom start`.
- `darkbloom cluster status` now answers in plain words: who leads, the model and how it is split, whether it serves
  through Darkbloom or locally, whether it serves now and if not why (the same reasons `darkbloom cluster` shows), and
  what to do. `--json` gives the same for scripts and agents, and the exit status says it too (0 serving, 3 not
  serving yet, 4 stopped, 5 the other Mac isn't answering, 6 not in a cluster). The earlier detailed report is
  `--details`.
- `darkbloom cluster --help` lists the other cluster commands and what each is for.
- `darkbloom cluster link --remove` on a paired Mac warns first that it undoes the working cable setup and stops the
  cluster on both Macs, and asks once (`--yes` for scripts).
- `darkbloom cluster stop` on the Mac that follows now stops the cluster on both Macs, as Stop does in
  `darkbloom cluster`, and says so. Before, it stopped only that Mac and left the other one waiting.
