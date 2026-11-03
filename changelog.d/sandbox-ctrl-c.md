### Ctrl-C stops sandbox commands that run the add-on, its installer or tail

- Ctrl-C now ends `darkbloom sandbox logs -f`. It also reaches the Darkbloom Sandbox installer during `darkbloom sandbox setup` (setup exits 130), the add-on's own `uninstall`, and the status of an add-on older than `status --json`. Before, the CLI ignored Ctrl-C while such a command ran and never passed it on, so `sandbox logs -f` kept the terminal until it was closed.
- A second Ctrl-C while the command still runs kills it, so a command that ignores Ctrl-C cannot hold the terminal. The CLI reports that as a stop by Ctrl-C, as for the first.
