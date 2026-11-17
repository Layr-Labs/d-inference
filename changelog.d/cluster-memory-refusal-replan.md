### A pair whose split one Mac's memory refuses moves to a split that fits

- When one Mac's memory check refuses its share twice because other apps hold the memory, the leading Mac plans the model again and now chooses first a split that each Mac's free memory holds. Before, the plan counted macOS's file cache, which the memory check stops counting once a load pushes apps into compression, so the re-plan chose the same split and the pair restarted it every 30 seconds without serving.
- Until the pair loads, each start of the refused part waits twice as long as the last, up to 5 minutes, so the Mac's apps aren't pushed into compression every 30 seconds.
- `DARKBLOOM_CLUSTER_MEMORY_REFUSAL_REPLAN=0`, exported before `darkbloom start` or `darkbloom cluster`, restores 0.10.14's behaviour.
