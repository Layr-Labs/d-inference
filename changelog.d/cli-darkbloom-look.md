### The everyday commands show the Darkbloom mark in a terminal

- In a terminal, `darkbloom start`, `stop`, `restart`, `status` and `update` open with the Darkbloom mark beside the
  command's name, blooming once as the cluster setup's does, and show its turning one-row live line while they wait
  for a drain, a restart or an update's download.
- Look only: every line the commands print is unchanged and in the same order, and so are their exit statuses.
- Scripts, logs, the background service's files, `NO_COLOR`, `TERM=dumb` and narrow windows keep exactly the plain
  output. `DARKBLOOM_NO_ANIMATION` or `CI` keeps the mark and the live line still.
- On a paired Mac, `darkbloom start` in a terminal opens the cluster's screen, which already draws the mark, so it
  isn't drawn twice.
- A command that refuses before doing any work (an unreadable pairing record, nothing to restart, flags that can't go
  together), or finds nothing to do (`stop --solo` with no single-Mac serving), prints only its lines, with no mark.
- The mark appears once, at the top of the command you ran: `unenroll` and `autopilot enable`, which run `stop --solo`
  and `start` inside themselves, show none.
