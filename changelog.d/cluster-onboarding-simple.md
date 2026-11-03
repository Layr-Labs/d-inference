### Simpler two-Mac cluster setup

- `darkbloom cluster` setup says far less: four steps (Connect, Pair, Model, Start), a line per thing that happened,
  and the next thing to do last. Every choice is a list (↑↓ and enter, as `darkbloom start` picks models; numbered in
  plain transcripts); q or Esc cancels.
- The model list shows only the models approved for clusters (GLM-5.3-Flash and Qwen3.8 27B) that the two Macs can
  serve, each with its size.
- The Mac you set up on leads and keeps leading: every plan puts rank 0 on it, the cluster service's own re-plans
  included, so a pair set up with 0.10.6 whose other Mac took over leading moves back at its next plan.
- macOS's password and Local Network prompts come at stated moments (sudo in the terminal over SSH); both Macs ask
  about Darkbloom's Local Network access right after pairing, and the setup waits until Allow or q.
- Both Macs confirm the pairing code; the Mac that follows only shows the status. The serving line says whether the
  pair earns through Darkbloom or serves locally only.
- `darkbloom doctor` includes the cluster's checks on a Mac paired for a cluster.
