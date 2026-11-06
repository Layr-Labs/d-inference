# Host Darkbloom Sandbox CI jobs

> Last updated: 2026-11-03

How to let this Mac run Darkbloom Sandbox jobs, approved GitHub Actions jobs in
Linux and macOS virtual machines, beside the inference provider: set it up,
check it, pause it and remove it. For Mac owners who already run `darkbloom`.
Inference pauses while a job runs, and each job pays its price minus a 10% fee
into your Darkbloom balance.

## Prerequisites

- A Mac with Apple silicon and macOS 27 or later, with room for at least one job
  after what stays yours and what inference keeps. `darkbloom sandbox setup`
  checks this before it installs anything; the rules are in the
  [CLI reference](./cli-reference.md#setup).
- Free disk for the jobs. A tenth of the disk, 50 to 100 GiB, stays free for
  you. The first job of a platform also needs that platform's VM images
  (Linux 4 GiB, macOS 46 GiB, nothing once installed). Each Linux job needs a
  30 GiB scratch disk and each macOS job 40 GiB.
- A Darkbloom account that Darkbloom approved for Darkbloom Sandbox from its
  waitlist, and this Mac linked to it with `darkbloom login`. `darkbloom sandbox
  setup` installs nothing until the account is approved (step 1).
- The Mac plugged in, never sleeping on its power adapter, and logged in at the
  desktop, where the add-on runs. Ethernet works better than Wi-Fi.
- Outbound HTTPS to `api-sandbox.darkbloom.dev`.

## Steps

1. Join the Darkbloom Sandbox waitlist, then wait for Darkbloom to approve your
   account:

   ```bash
   darkbloom waitlist sandbox
   ```

   The waitlist is for your account, not for this Mac: the command puts your
   account on it, sending nothing about this Mac, and prints your place in line.
   Run it again to see where you stand; it keeps your place. Darkbloom reviews
   accounts in the order they joined. `darkbloom sandbox setup` also offers to
   join when your account is not on the waitlist, and stops until it is approved.

2. Check this Mac and set it up:

   ```bash
   darkbloom sandbox setup
   ```

   Setup checks this Mac, then downloads the add-on's installer and asks it for
   the add-on's own plan. The installer verifies the release and runs the
   add-on's checks and sizing without installing anything. Setup prints the
   cores, memory and disk that plan counts and how many Linux and macOS jobs
   this Mac can run at a time, then what changes, and asks. If no job fits, it
   says how much disk one Linux job and one macOS job would need, and stops.
   Nothing is installed before you answer `y`. The installer then installs the
   add-on in `~/DarkbloomSandbox`. The plan needs add-on 1.1.1 or later. With an
   older installer, setup prints `[INFO] Sizing` and estimates with the same
   rules.
   To choose the number of jobs, add `--linux-slots <n>` and `--macos-slots <n>`;
   `--macos-slots 1` keeps one of macOS's two macOS VMs for your own use.
   To put the VM images and jobs on an external drive, add `--disk <volume>`,
   or pick the drive when setup asks; see
   [Use an external drive](#use-an-external-drive).

3. Approve this Mac in your browser. The installer opens the approval page with
   the code filled in, and setup prints the link and code as well. Sign in with
   the Darkbloom account that should receive the earnings and approve. Your
   `darkbloom login` session cannot approve a Mac. To approve from another
   device, add `--no-browser` to step 2 and open the printed link there.

4. Let the VM images download. After enrollment the add-on starts and downloads
   its VM images in the background, the sizes setup showed under Disk. The Mac
   takes jobs once an image is installed. To keep setup open until then, add
   `--wait-ready` to step 2.

## Use an external drive

If the internal disk is what limits this Mac, or to spare it the wear, give the
jobs another drive. The VM images and the jobs then use that drive. The add-on,
its settings and its logs stay in `~/DarkbloomSandbox`. This needs add-on 1.2.0
or later; with an earlier release setup says so and changes nothing.

1. Use a Thunderbolt or USB4 NVMe SSD that stays connected and powered. A job
   on a drive that goes away is stopped and is not paid.
2. Format it as APFS in Disk Utility. Erasing deletes everything on the drive.
   Setup never formats a drive.
3. Turn on ownership, which macOS leaves off for external drives. Setup offers
   to do this for you (step 4). To do it yourself:

   ```bash
   sudo diskutil enableOwnership /Volumes/FastSSD
   ```

4. Run `darkbloom sandbox setup`. On a first setup it lists the drives with
   room for jobs and asks where the VM images and jobs go. Press Enter to keep
   the internal disk, or type the drive's number. You can also name the drive.
   Repeat `--disk` for more drives, and add `--disk ~` to keep using the
   internal disk too:

   ```bash
   darkbloom sandbox setup --disk /Volumes/FastSSD
   ```

Setup checks each drive before it installs anything. When ownership is off,
setup prints the command and asks whether to run it. If you agree, sudo asks
for your password, and setup checks the drive again. With `--yes`, or without
a terminal, setup prints the command and stops. When a drive is not APFS, setup
stops and tells you to erase it as APFS in Disk Utility; setup never formats a
drive. The plan then shows each drive, its free space and the jobs it gets.
Each drive keeps its own free space: a tenth of the drive, 50 to 100 GiB.
Running setup again keeps the drives you chose; give `--disk` again to change
them. `darkbloom sandbox status` shows each drive, its free space and slots,
and what to do when one is not connected.

## Verify

```bash
darkbloom sandbox status
darkbloom status
```

`darkbloom sandbox status` shows the state, what it means for inference, free
slots, images and the console link (`--json` prints the add-on's own status).
`darkbloom status` adds a `Sandboxes:` line while the add-on is installed.
Settled jobs are in the console under **Billing → Earnings**.

## Pause, follow and remove

| Goal | Command |
|---|---|
| Let running jobs finish and take no new ones | `darkbloom sandbox pause` |
| Take jobs again | `darkbloom sandbox resume` |
| Follow the add-on's log | `darkbloom sandbox logs -f` |
| Change the jobs at a time | `darkbloom sandbox setup --linux-slots <n> --macos-slots <n>` |
| Put the images and jobs on an external drive | `darkbloom sandbox setup --disk /Volumes/<name>` |
| Remove the add-on and its files | `darkbloom sandbox uninstall` |

Uninstalling ends running jobs, which are not paid: pause first and uninstall
once they finish. Running `setup` again at any time is safe: it reports the
state, continues an unfinished setup or repairs the add-on.

On a Mac that is set up, `setup` also asks the installer for the add-on's plan
again. When the plan fits other job counts, for example after you freed disk,
setup shows them beside the installed ones and asks `[Y/n]`. Yes reinstalls
with the plan's counts and restarts the add-on. The installer does not wait
for jobs: if one is running, it refuses and changes nothing, and setup says to
run it again when the job finishes. With `--yes` or without a terminal, setup
applies the plan only when it adds jobs and removes none; otherwise it prints
the command that applies it. When the counts match, setup reports as before.
While jobs run, setup skips the check. The
[CLI reference](./cli-reference.md#setup) has the details.

## Troubleshooting

- **`You're on the Darkbloom Sandbox waitlist: #N in line`** (setup exits 1).
  Darkbloom has not approved your account for Darkbloom Sandbox yet; nothing
  was installed. Run setup again once `darkbloom waitlist sandbox` says your
  account is approved.
- **`Link this Mac to your Darkbloom account first`**. The waitlist needs your
  account: run `darkbloom login`, then setup again.
- **`Darkbloom revoked your account's access to Darkbloom Sandbox`**. Joining
  again does not restore it; contact Darkbloom.
- **`Could not reach the Darkbloom Sandbox waitlist at …`** (setup exits 1).
  Setup could not learn whether your account is approved, so it checked and
  installed nothing. Fix the reason it names, such as this Mac's connection,
  then run setup again.
- **`Free up N GiB of disk for one Linux job`.** No job fits in the free disk.
  The disk rules are under [Prerequisites](#prerequisites). Free the space it
  names, then run setup again.
- **`no macOS jobs (limited by free disk space)`, while Finder shows more
  free.** The plan counts what `df -h ~` shows as Avail. Finder also counts
  purgeable space, which macOS frees only when it needs to. Restart, or remove
  Time Machine local snapshots (`tmutil listlocalsnapshots /` lists them), to
  free it now. Setup's line `A macOS job needs about N GB more` says how much
  more free space a macOS job needs beside the planned Linux jobs. Then run
  setup again: it offers the new plan.
- **`On the waitlist`.** Darkbloom has not approved your account yet. With
  add-on 1.1.2 and later you can close the window: the Mac keeps waiting, also
  across restarts, and enrolls by itself once your account is approved;
  `darkbloom sandbox status` shows where it is. With an earlier add-on, press
  Ctrl-C if you like: the Mac enrolls once it is approved, and `setup` follows
  the waiting enrollment when you run it again. A restart ends that wait; run
  setup again after one.
- **`[FAIL] Work disk: … ignores file ownership`.** Ownership is off on the
  drive. Answer yes when setup offers to turn it on, or run the `↳ fix:`
  command (`sudo diskutil enableOwnership …`) yourself, then run setup again.
- **`Work disk: … offline` in `darkbloom sandbox status`.** The drive is not
  connected, so its slots take no jobs. Connect it again; its slots take jobs
  once its images are checked.
- **`[FAIL] Work disk: … is not APFS`** or **`is not a mounted drive`.** Format
  the drive as APFS in Disk Utility, or connect it, then run setup again.
- **`work disks need add-on 1.2.0 or later`.** The add-on release on offer
  cannot use other drives yet. Run setup without `--disk`.
- **`[WARN] Network`, `Power` or `Sleep`.** These do not block setup, but a
  sleeping, unplugged or dropped Mac loses its running jobs, and lost jobs are
  not paid. Follow the `↳ fix:` line.
- **`This Mac was not enrolled`** (exit status 3). The code was denied or
  expired, or the waitlist request ended. Run setup again for a new code.
- **`A job is running on this Mac`** (exit status 4). The installer refuses
  to replace the add-on or change its slots while a job runs, and changes
  nothing; it does not wait. Run setup again when the job finishes;
  `darkbloom sandbox pause` keeps new ones from starting. Setup never passes
  the installer's `--force`, which would stop running jobs, and stopped jobs
  aren't paid.
- **`This version of the add-on …`.** The add-on predates the command; it
  updates itself, or `darkbloom sandbox setup` updates it now.
- **`Sandboxes: installed; the add-on did not answer within 2s`.** `darkbloom
  status` gave up waiting; `darkbloom sandbox status` waits longer, and
  `darkbloom sandbox logs` shows what the agent is doing.

## Related

- [CLI reference: `darkbloom sandbox`](./cli-reference.md#darkbloom-sandbox): flags, eligibility rules and the installer and add-on contracts
- [CLI reference: waitlists](./cli-reference.md#darkbloom-waitlist): the waitlist commands and the request they make
- [Add-on hold](../architecture/addon-hold.md): how the provider pauses inference for jobs
- [Configuration](../reference/configuration.md#darkbloom-sandbox-cli): bounds and the test override
