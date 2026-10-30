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
   darkbloom waitlist sandbox join
   darkbloom waitlist sandbox
   ```

   The first command joins with this Mac's chip and memory and prints your place
   in line; the second shows where you stand. Darkbloom reviews accounts in the
   order they joined. `darkbloom sandbox setup` also offers to join when your
   account is not on the waitlist, and stops until it is approved.

2. Check this Mac and set it up:

   ```bash
   darkbloom sandbox setup
   ```

   Setup prints what it measured, whether this Mac is eligible and how many Linux
   and macOS jobs it can run at a time, then what changes, and asks. Nothing is
   downloaded before you answer `y`. It then downloads the add-on's installer,
   which verifies the release and installs the add-on in `~/DarkbloomSandbox`.
   To choose the number of jobs, add `--linux-slots <n>` and `--macos-slots <n>`;
   `--macos-slots 1` keeps one of macOS's two macOS VMs for your own use.

3. Approve this Mac in your browser. The installer opens the approval page with
   the code filled in, and setup prints the link and code as well. Sign in with
   the Darkbloom account that should receive the earnings and approve. Your
   `darkbloom login` session cannot approve a Mac. To approve from another
   device, add `--no-browser` to step 2 and open the printed link there.

4. Let the VM images download. After enrollment the add-on starts and downloads
   about 50 GiB of VM images in the background; the Mac takes jobs once an image
   is installed. To keep setup open until then, add `--wait-ready` to step 2.

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
- **`Not eligible: free up N GiB of disk`.** A tenth of the disk (50 to
  100 GiB) stays free for you and the images need 50 GiB more. Free the space
  it names, then run setup again.
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
- [CLI reference: waitlists](./cli-reference.md#darkbloom-waitlist): the waitlist commands and the request they make
- [Add-on hold](../architecture/addon-hold.md): how the provider pauses inference for jobs
- [Configuration](../reference/configuration.md#darkbloom-sandbox-cli): bounds and the test override
