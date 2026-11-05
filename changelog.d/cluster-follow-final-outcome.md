### The joining Mac ends with the leading Mac's outcome

- While the pair is offered to Darkbloom and waits for Apple's verification or for the coordinator, the joining Mac now
  keeps waiting. It shows a live row such as "Waiting for Apple to verify this Mac (Darkbloom retries by itself) · 2 of
  15 min". Before, it judged the pair by its own wait: on a real pair it ended with "✗ Not serving: This Mac isn't
  verified by Apple yet …" while the leading Mac showed "✓ Serving … through Darkbloom on both Macs" 41 s later.
- Its last word is the leading Mac's: the same ✓, or the same ✗ with its next step. When the leading Mac's start
  ends with ✗ on its screen, it publishes that ✗ in its status, and the joining Mac shows it named from its own side
  ("This Mac isn't logged in to Darkbloom …").
- "Choose Retry on the other Mac" appears only under that ✗, since the leading Mac's screen then shows Retry. It is no
  longer said while a part restarts by itself.
- With a leading Mac on an earlier release, which publishes no outcome, the joining Mac waits until the stage's
  15 minutes run out. It then ends with "✗ Not serving: The other Mac (…) didn't say how its start ended within
  15 minutes.", the last state it saw, and where to look.
