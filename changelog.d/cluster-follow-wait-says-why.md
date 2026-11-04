### The Mac that joins a cluster says what it waits for

- While the Mac that joined waits for the leading Mac to start, its line now says what the leading Mac is waiting on:
  Allow on its Local Network prompt, a model choice on its screen, a login, Try again, a copy, or the start itself.
  It also says how long it has waited out of 15 minutes, for example "Waiting for the other Mac (Apple M5 Max,
  128 GB): it's waiting for Allow on its Local Network prompt · 2 of 15 min (q leaves)". It only knows this when the
  leading Mac runs this release or a later one. With an older leading Mac it keeps the general words.
- The live line always fits the window, even after the window is made narrower. Before, a long line could wrap and
  leave a new copy of itself on screen at every redraw. A plain transcript (`NO_COLOR`, `TERM=dumb`, a pipe) gets one
  line per change, never one per tick.
- If the two Macs run different Darkbloom builds, the waiting Mac now stops at once with
  "✗ Not serving: The two Macs run different Darkbloom builds." It names both versions and says which Mac needs
  `darkbloom update`. The leading Mac ends with the same ✗. Any other refusal by the leading Mac ends the wait
  at once too, with its reason.
- If nothing starts within 15 minutes, the wait ends with a ✗. It says what the leading Mac was last doing, what to
  do on it, and how to check that both Macs run the same build. Before, it ended with a plain sentence.
- The leading Mac's wait for Allow on its Local Network prompt now shows a timer and gives up after 10 minutes. It
  ends with a ✗ that says where to turn Darkbloom on, and what to do when Darkbloom isn't in the list: macOS asks on
  that Mac's screen the next time it connects.
