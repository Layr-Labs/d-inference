### Sandbox setup can put the VM images and jobs on an external drive

- `darkbloom sandbox setup --disk <volume>` (repeatable) passes each drive to the add-on's installer, for its plan and its install. The VM images and the jobs go on those drives; the add-on, its settings and logs stay in `~/DarkbloomSandbox`. Add `--disk ~` to keep using the internal disk too.
- Before it downloads anything, setup checks each drive: mounted, APFS, ownership on. With ownership off it prints the exact command, such as `sudo diskutil enableOwnership /Volumes/FastSSD`, and stops. The command needs an administrator, so setup never runs it, and it never formats a drive.
- The plan shows each drive, its free space and the jobs it gets. When the installer refuses a drive, setup shows the installer's fix and stops.
- `--disk` needs an add-on release with work disks (1.2.0 or later). With an earlier release, setup says so and changes nothing. On a Mac that is set up, setup suggests `--disk` only when the installed add-on supports it.
