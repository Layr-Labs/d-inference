### Both Macs of a pair show how far the start is

- While the parts load, the leading Mac's screen shows one row per Mac with its share of the layers and the time:
  "This Mac: ready (layers 0–46)", "The other Mac: loading its share (layers 47–93)", or "part ended (exit 1);
  starts again in 5 s". A row that doesn't fit the window gets shorter instead of being cut. A plain transcript
  (`NO_COLOR`, `TERM=dumb`, a pipe) says each row once, when it changes.
- The leading Mac now publishes the start's step in its status: downloading, copying, stopping the model that served,
  loading, testing, or registering with Darkbloom. It also publishes a copy's or download's bytes as the sending Mac
  counts them, and which Mac's part is ready. The Mac that joined uses this to show the same step, a real progress bar
  during a copy or download, and the same per-Mac rows. While the model loads there is no percentage, because
  Darkbloom has no measure of it: you see a turning mark and the time.
- A Mac with an older Darkbloom ignores the new fields, and with an older leading Mac the joining Mac keeps its general
  words.
