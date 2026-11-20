### A switch to serve the network only on macOS 15.4 or later

- The serving start check has a build switch that requires macOS to report each process's original parent, which macOS does from 15.4. It is off in this release, so nothing changes. With it on, a network-serving start before macOS 15.4 is refused, says to update macOS, and does not ask launchd to start the service; `darkbloom start --local --here` is unchanged.
