### `stop --solo` on the wrong Mac finds the right one

- If `darkbloom stop --solo` finds no single-Mac serving on this Mac but finds it on the other Mac of the pair, it names that Mac and its process and offers to stop it there. `--yes` stops it without asking, for scripts. It no longer points to plain `darkbloom stop`, which stops the pair and leaves single-Mac serving running.
- While single-Mac serving blocks a started pair whose other Mac answers, `darkbloom start` starts the pair (in a terminal, the screen that offers to stop it). It no longer offers "Serve on this Mac alone", which would recreate the block.
- "Single-Mac serving is set up" now means its job is loaded, not that its file exists. After `stop --solo`, a pair whose other Mac goes quiet no longer gives up its part for single-Mac serving that can't come back.
