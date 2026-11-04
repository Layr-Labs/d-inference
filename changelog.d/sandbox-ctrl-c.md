### Sandbox commands stop at Ctrl-C, and setup shows the installer's lines as they arrive

- Ctrl-C now ends `darkbloom sandbox logs -f` with exit status 130, as `darkbloom logs --follow` ends. It also reaches the Darkbloom Sandbox installer during `darkbloom sandbox setup` (setup exits 130), the add-on's own `uninstall`, and the status of an add-on older than `status --json`. Before, the CLI ignored Ctrl-C while such a command ran and never passed it on, so `sandbox logs -f` kept the terminal until it was closed.
- A second Ctrl-C while the command still runs kills it, so a command that ignores Ctrl-C cannot hold the terminal. The CLI reports that as a stop by Ctrl-C, as for the first.
- `darkbloom sandbox setup` now shows each line from the installer as soon as the installer prints it. Before, the CLI received the installer's output only every 16 KiB or when the installer exited, so with `--no-browser` the approval link could stay hidden while setup waited for that approval.
