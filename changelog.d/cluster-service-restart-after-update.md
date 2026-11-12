### A pair's cluster service runs the installed release after `darkbloom update`

- A pair that serves only on its local API (or a Mac whose cluster service
  serves alone) kept its cluster service on the earlier release after
  `darkbloom update` on both Macs: the service's supervisor does not drain
  such a pair for an update, so it never restarted into the installed
  release, and `darkbloom restart` restarted only the pair's parts (0.10.12
  W1). The parts ran the installed release; the service's own changes, and
  the version it reports to the other Mac, waited for the next login.
- Now the first part the service starts from a newer installed release
  restarts the service's launchd job once, before it takes a request: the
  pair stops on that Mac and starts again on the installed release, as after
  a login. Only for the build's own job, only when its supervisor runs an
  older release than the part, and once per release in 6 hours; the part's
  log says so (`cluster part: this Mac's cluster service still runs …`). It
  runs in the parts of this release, so it also covers the update to it.
