### Two-Mac pairs: when the other Mac's part ends on its own, its log says why

- When the session on the Mac that follows ended because its own side closed, its `rank.log` and the incident it records said only "session fenced: follower endpoint closed". They now add what closed it: its worker reported a failure (with its reason), its owner process ended, a record from that process was refused, its time ran out, or its cleanup was asked for. Nothing else about the pair changes.
