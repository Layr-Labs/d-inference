### `darkbloom update` says when the disk is too full, and doesn't promise a restart it may not get

- An update that fails to download or install on a nearly full disk now says how much space is free and about how much the update needs (twice the installed app's size, for the download and its unpacked copy), and to free some space and run `darkbloom update` again. Before, it said only "failed to replace binary: process exited 1". With room on the disk, the message is unchanged.
- On a pair that serves only on its local API, `darkbloom update` no longer says the cluster service restarts "now" before the service has answered: it says it asked for a restart without waiting for the other Mac. When the service puts the restart off, the command still ends with "Not restarted now" and when it tries again.
- Messages only; the update itself is unchanged.
