# Host Darkbloom Sandbox CI jobs

> Last updated: 2026-10-30

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
- A Darkbloom account that Darkbloom approved to host sandboxes. An account not
  approved yet joins a waitlist, and the Mac enrolls once it is approved.
- The Mac plugged in, never sleeping on its power adapter, and logged in at the
  desktop, where the add-on runs. Ethernet works better than Wi-Fi.
- Outbound HTTPS to `api-sandbox.darkbloom.dev`.

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

## Troubleshooting

- **`Free up N GiB of disk for one Linux job`.** No job fits in the free disk.
  The disk rules are under [Prerequisites](#prerequisites). Free the space it
  names, then run setup again.
- **`On the waitlist`.** Darkbloom has not approved your account yet. Press
  Ctrl-C if you like; the Mac enrolls once it is approved, and `setup` follows
  the waiting enrollment when you run it again.
- **`[WARN] Network`, `Power` or `Sleep`.** These do not block setup, but a
  sleeping, unplugged or dropped Mac loses its running jobs, and lost jobs are
  not paid. Follow the `↳ fix:` line.
- **`This Mac was not enrolled`** (exit status 3). The code was denied or
  expired, or the waitlist request ended. Run setup again for a new code.
- **`Jobs are running on this Mac`** (exit status 4). An add-on update or a
  slot change waits for running jobs; run setup again once they finish.
- **`This version of the add-on …`.** The add-on predates the command; it
  updates itself, or `darkbloom sandbox setup` updates it now.
- **`Sandboxes: installed; the add-on did not answer within 2s`.** `darkbloom
  status` gave up waiting; `darkbloom sandbox status` waits longer, and
  `darkbloom sandbox logs` shows what the agent is doing.

## Related

- [CLI reference: `darkbloom sandbox`](./cli-reference.md#darkbloom-sandbox): flags, eligibility rules and the installer and add-on contracts
- [Add-on hold](../architecture/addon-hold.md): how the provider pauses inference for jobs
- [Configuration](../reference/configuration.md#darkbloom-sandbox-cli): bounds and the test override
