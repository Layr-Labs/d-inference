### Runtime-outdated status and update

- Act on `runtime_status{verified:false}` instead of only logging it: `darkbloom status` now shows when the coordinator has excluded this provider from routing for a runtime-hash mismatch, with the fix (`darkbloom update`), and an enabled auto-update runs one immediate check (at most once per 10 minutes) through the existing background updater. The recorded mismatch clears after 15 minutes without a fresh one, since the coordinator only ever re-sends the failing status while it lasts.
