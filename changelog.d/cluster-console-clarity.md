### `darkbloom cluster` after setup works like `darkbloom start`

- Run again on a set-up pair, `darkbloom cluster` (and `darkbloom start` on a paired Mac) opens with both Macs and the
  cable ("This Mac (Studio A) leads · the other Mac (Apple M3 Ultra, 256 GB) follows · cable ready") and the pair's
  status, then the pair's model list instead of a menu. The model serving now ("serving now", or "last used" when
  stopped) is preselected: Enter keeps it, or starts it again in the mode it served in.
- Each model shows its modes with the speed this pair served it at, or "not measured on these Macs yet". A model that
  runs more than one way asks how both Macs split it (the fastest measured first, tensor parallel or pipeline one
  keypress away, on mixed Macs too).
- A line under the models switches between local only and serving through Darkbloom (both logins are checked first,
  before the local API stops); another starts over after one question.
- Choosing another model while one serves asks once, then says "✓ Stopped … on both Macs" and shows each Mac's load.
  Choosing the serving model in its mode sends one test request and shows its result ("Already serving …; test
  response in 0.61 s", or the ✗ block with its choices); a pair served only through Darkbloom says this Mac has no local
  API to test from.
- Every start ends like `darkbloom start`: the outcome block, then the model in its mode and split, the Macs, where it
  serves, the log, "Starts by itself at login on both Macs.", and `darkbloom stop` / `restart` / `status`. A pair that
  does not serve keeps its ✗ block with Retry, Change model, Serve locally only and Diagnostics.
- The Mac that follows says that its part runs by itself, where to change the model, and that `darkbloom stop` there
  stops both Macs; Enter closes it.
- When the other Mac does not answer, the screen no longer says `darkbloom cluster stop` turned its service off, and
  says to run `darkbloom start` or `darkbloom cluster` there.
- A fresh setup opens with what it will ask and how long it takes.
- During the first setup the Mac that joins keeps its window open: it waits for the leading Mac to choose the model,
  follows the start, and ends with the same ✓ or ✗ block ("Choose Retry on the other Mac" after ✗), also when the leading
  Mac offers the pair to Darkbloom late (its status says so until it has, as a start, never ✓) or its test request
  fails; q leaves and the pair keeps going. The registration now reads "Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to
  accept this pair…" instead of the approval line.
