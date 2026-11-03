### Simpler two-Mac cluster setup

- `darkbloom cluster` setup is shorter: four steps (Connect, Pair, Choose a model, Start), one line for each thing that
  happened, and the next thing to do as each screen's last line. Every choice, a short model copy included, is a list
  moved with ↑↓ and taken with enter, as `darkbloom start` picks models (numbered in plain transcripts); q or Esc
  cancels, and no prompt asks for a key to do something.
- The model list shows only the models approved for clusters (GLM-5.3-Flash and Qwen3.8 27B) that the two Macs can
  serve; a named model that is not approved is refused.
- The Mac you set up on leads and keeps leading: every plan puts rank 0 (the API and the coordinator's registration)
  on it, the cluster service's own re-plans included, so a pair set up with 0.10.6 whose other Mac took over leading
  moves back at its next plan.
- Connect names the macOS approvals each Mac asks for: the cable's port (with sudo in the terminal over SSH, instead of
  a script to run by hand) and Darkbloom's Local Network access, which both Macs ask right after pairing; the setup
  waits until Allow or q.
- Both Macs confirm the pairing code. The Mac that follows shows the status and where to manage the cluster; both Macs
  say whether their window can close, and a pair served through Darkbloom says it earns for the public requests it
  serves.
- `darkbloom doctor` includes the cluster's checks on a Mac paired for a cluster.
