### A second Ctrl-C stops the provider at once

Ctrl-C (or `SIGTERM`) starts the provider's drain, which waits for running
requests, up to 10 minutes by default. A second Ctrl-C during that drain now
ends the process at once, with status 130, and says it didn't finish the
drain. Before, a second Ctrl-C did nothing. A second `SIGTERM` or `SIGHUP`
still only joins the drain, because the cluster supervisor and launchd may
send `SIGTERM` more than once.
