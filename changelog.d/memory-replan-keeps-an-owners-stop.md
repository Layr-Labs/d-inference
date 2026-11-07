### The memory re-plan keeps a stopped pair stopped and a started one started

- When a Mac's part of a pair is refused at load twice because its memory moved, the leading Mac plans the model again on the memory now. That re-plan could come due right after you stopped the pair with `darkbloom stop`, and then started it again. It now does nothing once the pair is stopped, as the leading Mac's steps after an update already do.
- When that re-plan's own stop of the pair failed (the other Mac didn't answer, or a part didn't release in time), the pair stayed stopped on both Macs until someone ran `darkbloom cluster`. Now the pair stays started, and the re-plan can come due again.
