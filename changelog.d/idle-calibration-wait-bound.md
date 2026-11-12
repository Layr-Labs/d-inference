### A request no longer waits forever behind the idle speed check

- Before, a request that arrived while the provider ran its idle speed check (MiMo repeats it whenever the Mac is idle) waited for the check to finish, with no time limit, and ignored its coordinator's cancel. If the check stopped making progress, every later request on the Mac was accepted and never started: the coordinator timed each one out, and `darkbloom stop` waited 600 s for them and gave up.
- Now a cancelled request stops waiting at once, and any request stops waiting after 30 s and is refused as busy, so the coordinator sends it elsewhere. While the check is overdue the model reads `crashed` in the heartbeat, so no new requests are routed to it; it serves again as soon as the check finishes.
