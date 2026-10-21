### Watchdog restart acknowledgement

- When a provider job disappears between the watchdog's launchd check and kickstart, report that no restart occurred and restore the previous crash-loop backend guard. Keep stopped or uninstalled jobs unloaded instead of recording a restart that launchd refused.
