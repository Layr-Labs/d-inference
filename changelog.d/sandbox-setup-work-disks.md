### Sandbox setup can put the VM images and jobs on an external drive

- `darkbloom sandbox setup --disk <volume>` (repeatable) passes each drive to the add-on's installer, for its plan and its install. The VM images and the jobs go on those drives; the add-on, its settings and logs stay in `~/DarkbloomSandbox`. Add `--disk ~` to keep using the internal disk too.
- Without `--disk`, a first setup at a prompt lists the external APFS drives with room for jobs and asks where the VM images and jobs go. Enter keeps the internal disk.
- Setup checks each drive before it installs anything: mounted, APFS, ownership on. With ownership off it prints the exact command, such as `sudo diskutil enableOwnership /Volumes/FastSSD`, and offers to run it; sudo asks for your password. With `--yes` or without a terminal it prints the command and stops. Setup never formats a drive.
- The plan shows each drive, its free space and the jobs it gets. When the installer refuses a drive, setup shows the installer's fix and stops.
- `darkbloom sandbox status` shows each work disk, its free space and slots, and what to do when one is not connected.
- `--disk` needs an add-on release with work disks (1.2.0 or later). With an earlier release, setup says so and changes nothing. On a Mac that is set up, setup suggests `--disk` only when the installed add-on supports it.
