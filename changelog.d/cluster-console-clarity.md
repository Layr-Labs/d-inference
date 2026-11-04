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
  follows the start, and ends with the leading Mac's own outcome instead of a test of its own: ✓ with the leading Mac's
  response time, or the same ✗ and reason ("Choose Retry on the other Mac" after ✗). Both windows tell the same story,
  serving locally only or through Darkbloom, also when the leading Mac's test request fails or when it checks with
  Darkbloom before it offers the pair (until then, neither Mac's status shows ✓). q leaves and the pair keeps going.
- Once the pair is registered, the screen says "Offered to Darkbloom as a pair for <model>; waiting for Darkbloom to
  accept this pair…" instead of "Registered with the coordinator as a cluster member" and the approval's ID, which read
  as if Darkbloom had already accepted the pair.
- When the other Mac isn't found within about 25 s at "2/4 Pair", the screen says what to check (the other Mac on this
  screen, macOS's firewall, or pairing directly with `darkbloom cluster pair --listen` and `--connect <address>`) and
  keeps waiting.
- A part that stops serving is reported with its own reason ("the coordinator reported this member's runtime as
  outdated", from its log), not "CancellationError()", on screen and in the diagnostics file.
- Switching how a pair serves no longer announces the result before it is known.
- The serving model chosen in another mode asks as a mode change ("Switch Gemma 4 26B from tensor parallel to pipeline?
  It stops serving on both Macs while it loads again …"), and the list names the mode it serves in when it shows another
  ("serving now in pipeline"); a set-up pair with no model to list (or whose planning fails)
  still offers Start over and Quit; a pair that doesn't serve is never marked "serving now"; a failed test says "Not
  serving" once, and its Retry waits for the pair as the start's Retry does.
- A mode is offered only where it keeps every feature of the model. Qwen 3.8 27B is therefore offered in tensor
  parallel only: in pipeline it would lose image and video input and logprobs. Choose the mode on the leading Mac; a
  model chosen on the Mac that follows starts in the mode Darkbloom's plan picks.
- The status shows the leading Mac's latest test. When a later test fails (testing the serving model again, its Retry,
  or the test after switching between local only and serving through Darkbloom), the status shows ✗ with "The last
  test from the leading Mac failed." instead of the earlier ✓ and response time. Switching between local only and
  serving through Darkbloom clears the test results, as a new start or a stop does.
