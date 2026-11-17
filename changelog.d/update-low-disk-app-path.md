### `darkbloom update`'s low-disk message now appears

- 0.10.14 added a line to a failed update on a nearly full disk saying how much space is free and how much the update needs, but it never showed: the CLI runs through a symlink in `~/.darkbloom/bin/`, so it couldn't find the app to size it. It now follows the symlink to the app. Messages only.
