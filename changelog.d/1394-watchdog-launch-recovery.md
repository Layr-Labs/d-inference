### Interrupted watchdog launch recovery

- Recover a candidate's launch receipt when the watchdog exits after starting it but before recording success. A running candidate that never produces a heartbeat then reaches the existing startup timeout; missing launch evidence does not count as a failed start.
- Preserve unproven launch intent across health observations before restart. Require comparable saved and current launch evidence so an old serving process cannot acquire a false failed-start timeout when baseline evidence is missing or partial.
