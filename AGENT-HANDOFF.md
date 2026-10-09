# Agent handoff: two-Mac clustering

Start here. This branch carries the experimental two-Mac ("cluster") serving
foundation and the work to make it run for real.

| Read | For |
|---|---|
| [handoff/HANDOFF.md](handoff/HANDOFF.md) | Current status by gate, what is blocked and on whom, how to resume |
| [handoff/DESIGN-gap-map.md](handoff/DESIGN-gap-map.md) | Every known defect and missing piece, with its status |
| [handoff/EVIDENCE-LEDGER.md](handoff/EVIDENCE-LEDGER.md) | What was actually run, on which machine, with what result |
| [handoff/RUNBOOK-two-mac.md](handoff/RUNBOOK-two-mac.md) | Commands that have been run successfully here, and the ones still unverified |
| [libs/darkbloom-cluster/README.md](libs/darkbloom-cluster/README.md) | The shared control, security and runtime modules |
| [libs/darkbloom-cluster-worker/README.md](libs/darkbloom-cluster-worker/README.md) | The native rank worker and the two-rank transport check |
| [docs/reference/cluster-control-protocol.md](docs/reference/cluster-control-protocol.md) | Wire contract between coordinator, members and workers |

## Rules that are easy to break

- A passing mock, pipe fixture or loopback check is never a hardware or model
  pass. Record unit, integration, physical and real-model results separately.
- Never report a TCP, loopback or single-host run as an RDMA result. Record
  which device carried the bytes.
- Never end a rank that holds a loaded model with SIGKILL. Earlier work on the
  same hardware recorded GPU-wired memory left without an owner until reboot.
  Stop through the owner; let the worker release and exit.
- Do not change RDMA, network, firewall or other system settings on either Mac.
  Name the change and ask.
- One heavy Swift/Metal/GPU job per machine at a time.
- Model identity comes from the manifest, config and tensor evidence, not from
  a directory or branch name.
- Machine addresses, host names and serials stay out of committed files.
