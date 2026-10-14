### Re-arm crash recovery after a failed drained relaunch

- Restore the crash-recovery watchdog when `darkbloom restart` or a `darkbloom update` restart has drained the provider and stopped the old instance but the relaunch then fails. Automatic crash recovery is re-armed instead of being left disabled until an operator intervenes. The drain-timeout fence is unchanged and still leaves recovery disabled pending a retry or `--force`.
