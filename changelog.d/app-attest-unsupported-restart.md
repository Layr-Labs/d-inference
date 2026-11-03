### App Attest recovers by itself after a self-update

- A provider that launchd runs now relaunches through launchd after a startup self-update, as it already did after a background update. Only a provider that launchd does not run, such as `darkbloom start --foreground` in a terminal, replaces itself in place. A background update or App Attest restart in such a provider no longer starts the LaunchAgent instead.
- When App Attest reports `is_supported_false` on a Mac that the coordinator verified for App Attest in the last 7 days, the provider restarts once through launchd. It waits until the state lasts 5 minutes and the provider is idle, and it checks Apple's answer again after the drain. This restart and the stall restart share one limit: one automatic App Attest restart per 6 hours.
- The provider keeps the time of its last App Attest authorization in `app-attest-verified.json` beside the daemon state file.
