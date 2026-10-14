### A Mac pair serves locally when its coordinator has no cluster support

- A cluster whose coordinator cannot take its cluster member role (unreachable, or a coordinator that answers the member's registration as an ordinary provider's because it predates the role) now serves on the leader's local API only, with the same local token as `darkbloom start --local`, instead of restarting every 38 s without ever serving. No public traffic reaches it and nothing is advertised to the coordinator; the Macs stay held for the cluster as before.
- The onboarding screen and `darkbloom cluster` status say so in one line: "Serving locally on this Mac's API; public serving needs a coordinator with cluster support." The next start registers normally once the coordinator supports the role.
- A coordinator that refuses this member or its pairing is still a refusal: that start fails as before.
