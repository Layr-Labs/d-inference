# Host Darkbloom Sandbox CI jobs

> Last updated: 2026-11-03

How to let this Mac run Darkbloom Sandbox jobs, approved GitHub Actions jobs in
Linux and macOS virtual machines, beside the inference provider: set it up,
check it, pause it and remove it. For Mac owners who already run `darkbloom`.
Inference pauses while a job runs, and each job pays its price minus a 10% fee
into your Darkbloom balance.

## Prerequisites

- A Mac with Apple silicon and macOS 27 or later, with the memory, cores and
  free disk for at least one job: see [What this Mac needs](#what-this-mac-needs).
  `darkbloom sandbox setup` measures this Mac and shows its plan before it
  installs anything.
- A Darkbloom account that Darkbloom approved to host sandboxes. An account not
  approved yet joins a waitlist, and the Mac enrolls once it is approved.
- The Mac plugged in, never sleeping on its power adapter, and logged in at the
  desktop, where the add-on runs. Ethernet works better than Wi-Fi.
- Outbound HTTPS to `api-sandbox.darkbloom.dev`.

### What this Mac needs

Read this before you run setup. Setup uses the same rules and shows the result
for this Mac (step 1); nothing changes until you answer `y`. The rules as a
table are in the [CLI reference](./cli-reference.md#setup).

**Memory and cores.** Jobs get only what is left after what stays yours and
what inference keeps:

- You keep a quarter of the cores (at least 2) and a quarter of the memory (at
  least 8 GB).
- When the inference provider runs on this Mac, it keeps another quarter of the
  memory.
- Each Linux job takes 4 cores and 16 GB of what is left. Each macOS job takes
  8 cores and 16 GB. A Mac runs at most 16 Linux jobs and 2 macOS jobs (macOS
  runs at most two macOS VMs, your own included).

| To run at a time | Memory without inference | Memory with inference | Cores |
|---|---|---|---|
| One Linux job | 24 GB | 32 GB | 6 |
| One macOS job | 24 GB | 32 GB | 10 |
| One Linux and one macOS job | 43 GB (a 48 GB Mac) | 64 GB | 15 (a 16-core Mac) |

Jobs are counted at the smaller VM size. Some repositories ask for a larger VM
(Linux 8 cores and 32 GB, macOS 12 cores and 32 GB). Such a job starts only when
this Mac reports that much free; a 12-core, 32 GB macOS job beside inference
takes 16 cores and 64 GB.

**Disk.** On the disk that holds your home folder:

- A tenth of the disk, at least 50 GiB and at most 100 GiB, always stays free
  for you.
- The first job of a platform also needs that platform's VM images: Linux
  4 GiB, macOS 46 GiB (nothing once they are installed).
- Each Linux job needs 30 GiB for its scratch disk, and each macOS job 40 GiB.

So a first install needs, above the free tenth: about 34 GiB for one Linux job,
86 GiB for one macOS job, or 120 GiB for one of each. Free disk is what
`df -h ~` shows under `Avail`.

**Recommended Macs.**

| Tier | Cores | Memory | Free disk before setup | Jobs |
|---|---|---|---|---|
| macOS and Linux | 24 or more | 128 GB or more | 400 GB or more | A macOS job and Linux jobs at the same time |
| macOS | 16 or more | 64 GB or more | 250 GB or more | Usually one job at a time, macOS or Linux; with 128 GB, a Linux job beside a macOS one |
| Linux only | 10 to 14 | 32 GB or more | 100 GB or more (150 GB on a disk larger than 512 GB) | Linux jobs only |

Examples, with enough free disk and the inference provider running unless
stated:

| Mac | Linux jobs | macOS jobs |
|---|---|---|
| 8 cores, 16 GB | 0 (setup stops) | 0 |
| 12 cores, 32 GB | 1 | 0 |
| 16 cores, 48 GB | 1 | 0 (1 without inference) |
| 16 cores, 128 GB | 1 | 1 |
| 24 cores, 192 GB | 2 | 1 |
| 32 cores, 512 GB | 2 | 2 |

## Steps

1. Check this Mac and set it up:

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

2. Approve this Mac in your browser. The installer opens the approval page with
   the code filled in, and setup prints the link and code as well. Sign in with
   the Darkbloom account that should receive the earnings and approve. Your
   `darkbloom login` session cannot approve a Mac. To approve from another
   device, add `--no-browser` to step 1 and open the printed link there.

3. Let the VM images download. After enrollment the add-on starts and downloads
   its VM images in the background, the sizes setup showed under Disk. The Mac
   takes jobs once an image is installed. To keep setup open until then, add
   `--wait-ready` to step 1.

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
- [Add-on hold](../architecture/addon-hold.md): how the provider pauses inference for jobs
- [Configuration](../reference/configuration.md#darkbloom-sandbox-cli): bounds and the test override
