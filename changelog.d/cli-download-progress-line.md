### One progress line for model downloads

- `darkbloom models download` and the `darkbloom start` picker show one line for the whole model, redrawn in place at most four times a second: a bar, the percent, the bytes, the rate and the time left. It reads "Verifying" while the files are checked and ends as `Downloaded <id> (16.3 GB in 2m 10s)` or with where the download stopped. They no longer print a line for every file or a block of per-file bars.
- Without a terminal (a pipe, a log, the desktop app) the download prints plain lines with no carriage returns: the first at once, then at most one per 30 s and 10 points, one at 100%, and the same last lines. The desktop app reads its download progress from them.
- `darkbloom cluster` shows a model download or a copy over the cable on its live line instead of adding a line every second. A plain transcript keeps the first report, about one per 30 s and 10 points, and the lines for the record.
- Sizes in the line are decimal, as the catalog gives them.
