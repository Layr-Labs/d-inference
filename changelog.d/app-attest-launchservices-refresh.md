### App Attest keeps working after a self-update

- After a self-update, 12–15% of updating macOS 27 Macs reported App Attest as unsupported (`is_supported_false`) for minutes to hours. Restarting did not help: 0.10.7's automatic restart for this state fixed 1 of 117 Macs. Macs without the Darkbloom MDM profile received no inference until it cleared. The cause: Apple's answer depends on macOS's record of the installed app (LaunchServices), and the update replaced `Darkbloom.app` without refreshing that record.
- The updater now refreshes that record right after it installs a release.
- When Apple first reports App Attest as unsupported, the provider now refreshes the record for its own app and asks Apple again before it answers the coordinator, once each time the provider starts. This also covers the update to this release, which the previous release's updater installs.
- When the provider already runs in the logged-in GUI session, `darkbloom doctor` no longer advises logging in through Screen Sharing and restarting for `is_supported_false`. It explains that this usually follows a self-update and prints the `lsregister -f` command that refreshes the record by hand.
