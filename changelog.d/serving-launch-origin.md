### Network serving runs only as Darkbloom's background service

- A release build now serves the network only when Darkbloom's background service started it. A copy started any other way, for example `darkbloom start --foreground` typed into a terminal, says so, asks the background service to start, and exits. `darkbloom start`, `darkbloom start --local --here`, two-Mac clusters, updates, rollback and crash recovery work as before.
