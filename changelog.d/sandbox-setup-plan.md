### Sandbox setup shows the add-on's own sizing plan

- `darkbloom sandbox setup` now asks the Darkbloom Sandbox installer for the add-on's own plan before it asks you to confirm. After its own chip, macOS, session, network, power and sleep checks, setup runs the downloaded installer with `--plan` (add-on 1.1.1 and later). The installer verifies the release and sizes this Mac without installing anything. Setup then prints the plan's cores, memory and disk lines and how many Linux and macOS jobs this Mac can run at a time. Example: `Disk: 157 GiB free; 100 GiB stays free for you; Linux images 4 GiB + 30 GiB per Linux job; macOS images 46 GiB + 40 GiB per macOS job`.
- Disk follows the add-on's rules. A tenth of the disk (50 to 100 GiB) stays free. The first job of a platform also needs that platform's VM images (Linux 4 GiB, macOS 46 GiB, nothing once installed). Each Linux job takes 30 GiB and each macOS job 40 GiB.
- When no job fits, setup prints the plan's message and how much disk to free for one Linux job and for one macOS job. It then stops without installing.
- The installer is now downloaded before the question, so the plan is shown before you confirm. Nothing is installed before you answer `y`.
- With an older installer that cannot report a plan, setup prints `[INFO] Sizing` and estimates with the same rules.
