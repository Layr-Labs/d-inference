### Updates install only the version the app is signed as

- The self-updater staged a release after checking its hashes and code
  signature but never compared the coordinator's `version` with the version the
  app is signed as, so an older signed build offered under a newer version could
  pass the no-downgrade check and install. Staging now requires the signed
  app's `CFBundleShortVersionString` to equal the release's `version` exactly.
