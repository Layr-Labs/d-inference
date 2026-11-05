### A pair Mac left on an older release catches up with the other Mac within a minute

- When one Mac of a `darkbloom cluster` pair already runs a newer release (it updated alone, through single-Mac serving, `darkbloom update`, or because this Mac was asleep at the pair's update slot), the other Mac's cluster service notices within a minute and updates right away, instead of waiting for the pair's next update slot.
- With automatic updates off, the cluster service log says which version the other Mac runs and to run `darkbloom update` on this Mac.
- Each newer release triggers one immediate update attempt. If that attempt fails, the Mac tries again at the pair's update slots as before. A release quarantined on this Mac is never installed this way.
