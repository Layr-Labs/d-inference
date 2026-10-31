### Faster recovery from an isolated crash

- The watchdog restarts a provider that crashed after a long run on its next check, about 1–2 minutes after the crash instead of 6–7. An outage that would continue a crash-loop chain (a crash within 15 minutes of the last restart) still waits the 5-minute grace, so the crash-loop guard and rollback behave as before.
