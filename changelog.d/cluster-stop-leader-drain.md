### Cluster stop ordering

- A paired leader now retires its owned part before asking its follower to stop, preserving the native shutdown channel. Failed retirement or missing peer acknowledgement keeps the login service available for recovery and returns an error.

Require a fresh local supervision acknowledgement before stopping the peer so stale idle status cannot bypass a child start already in flight.

Keep follower lease intent alive through local planned drain; serialize background serve/stop reconciliation and wait for outstanding running leases before publishing stop acknowledgement. A stop the pair could not finish exits with status 1 and the pair's reason, without usage text.
