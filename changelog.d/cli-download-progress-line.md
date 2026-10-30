### One progress line for model downloads

- `darkbloom models download` and the `darkbloom start` picker show one line for the whole model, redrawn in place at most four times a second: a bar, the percent, the bytes, the rate and the time left, leaving out what does not fit the window's width. They no longer print a line for every file or a block of per-file bars.
- The line keeps its shape while the window keeps its width: each figure has a fixed column, sized for its widest form, so the bar and the figures do not move as the numbers change. The rate and the time left appear after 2 seconds, and a time left over 24 hours is not shown.
- The line reads "Verifying" while the files are checked, then ends with one line: `✓ Downloaded <name> (16.3 GB in 2m 10s)`, `✓ <name> is already downloaded (16.3 GB)`, where the download stopped, or `Verification of <id> failed: <reason>`. The picker no longer adds its own "Downloaded" line, and `darkbloom models download` ends with `Cached at <path>` instead of `Done. Cached at <path>`.
- Without a terminal (a pipe, a log, the desktop app) the download prints plain lines with no carriage returns: the first at once, then at most one per 30 s and 10 points, one at 100%, and the same last lines. The desktop app reads its download progress from them.
- `darkbloom cluster` shows a model download or a copy over the cable on its live line instead of adding a line every second. A plain transcript keeps the first report, about one per 30 s and 10 points, and the lines for the record.
- Sizes in the line are decimal, as the catalog gives them.
