### `darkbloom cluster leave`: leave a pair in one command

- `darkbloom cluster leave`, on either Mac of a pair, stops this Mac's part (the pair stops on both Macs while the other Mac answers, then this Mac's cluster service leaves login) and forgets this Mac's pairing, the same steps `darkbloom uninstall`, **Start over** and `darkbloom cluster pair --forget` take. Leaving no longer takes four steps: `cluster pair --status`, reading a pin, `cluster pair --forget <pin>`, then `start`.
- In a terminal it says what leaving does and asks `Leave the pair? [y/N]` (No by default); without a terminal it needs `--yes`. A part that doesn't stop leaves the Mac paired, and the command says so.
- It ends with what happens to the other Mac (it stopped too, or wasn't reached, and keeps its pairing until you run `darkbloom cluster leave` there), that `darkbloom start` serves each Mac alone, and that `darkbloom cluster` on each Mac pairs them again.
- While leaving, and in `darkbloom uninstall`, the stop no longer says "Run `darkbloom cluster` to start it again" or to stop the other Mac's service with `cluster stop --service`: the summary says what to do on the other Mac.
