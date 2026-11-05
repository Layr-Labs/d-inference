### The second Mac of a pair waits for the new setup after an update

- After the pair restarts into a new release, the Mac that follows no longer starts its part from the setup it saved
  for the previous release. That setup still names the previous release's files, so the part ended within a second,
  again and again ("Installed input identity or SHA-256 differs"), until the leading Mac sent the setup for the new
  release: on the M5 Ultra pair's update to 0.10.8, six times in about 2 minutes.
- It now waits for the leading Mac's setup and says so once: `this Mac runs Darkbloom v<version>, but its saved setup
  is for an earlier build: waiting for the other Mac's setup for v<version> (the old setup is not started)`. Every
  check of the installed files stays as strict; a setup that does not match them is never loaded.
- The leading Mac, waiting for both Macs to run the new release, checks again every 5 seconds instead of every
  minute, so it sets the pair up again sooner.
