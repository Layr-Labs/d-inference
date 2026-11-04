### `darkbloom cluster` says Serving and Done only once the model is loaded

- The setup ends with its outcome between two rules: `✓ Serving <model> through Darkbloom on both Macs (<split>)` (or
  `on this Mac's local API only`) with the API and the test response, then Done; or `✗ Not serving: <reason>.` with
  the next step. Before, a pair registered with the coordinator said Serving and Done on both Macs while nothing was
  loaded.
- Such a pair is now awaited, at most 15 minutes, until both Macs loaded the model and it answered its first request.
- The reasons it names: a Mac without a Darkbloom login, a Mac Apple hasn't verified yet (with when Darkbloom retries
  by itself; don't restart either Mac until then), a Mac without free memory for its share, or a part that keeps
  ending. **Retry**, **Change model**, **Serve locally only** and **Diagnostics** follow; q exits with status 1 and
  never says Done.
- Switching a serving pair between serving through Darkbloom and locally only, from the leading Mac, now ends the same
  way as a start: tested (or, for a pair registered with the coordinator, awaited until it serves), then the outcome
  block. Before, a registered pair was called serving at once.
- A missing login is named before the Start step starts anything, with **Log in on this Mac** (or **Check again**),
  **Serve locally only** and **Cancel**.
- The Start step says loading takes a few minutes for a large model; a color terminal shows one live row per Mac with
  its time so far.
- `darkbloom cluster` status calls a registered pair serving only while it serves, else
  `<model> is not serving yet: <reason>.`, and says a Mac serving alone is still loading until its solo server answers.
  The other Mac shows the same outcome block, and its setup ends with the same ✓ or ✗ as the leading Mac.
