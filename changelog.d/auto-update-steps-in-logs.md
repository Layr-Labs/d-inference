### `darkbloom logs` keeps a single Mac's update steps

- A single Mac's background update now writes one fixed public line for each step (available and staging, staged and draining, restarting, deferred, and each failure) at the level macOS unified logging keeps on disk, so `darkbloom logs --last 24h` still shows an update hours later.
- Before this, the update's progress lines were private info lines, which unified logging keeps only in memory, so the log showed no update at all. Those lines stay as they were. A check that finds the Mac up to date adds no line.
