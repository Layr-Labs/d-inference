### CI: the desktop review package asks Darkbloom first

- The manually dispatched Desktop App job that builds the unsigned macOS review package (`unsigned-desktop-review`) now asks the Darkbloom plane for a sandbox Mac on lane `desktop-package`. It falls back to `blacksmith-12vcpu-macos-27` when the plane does not grant it.
- The job is renamed from `review-package` to `desktop-package`, so that its lane has the job's name, as the lane of every unsharded routed job does.
- Pull requests and pushes do not ask for this lane: the job runs only on manual dispatch.
