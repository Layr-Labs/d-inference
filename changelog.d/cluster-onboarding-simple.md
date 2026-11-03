### Simpler two-Mac cluster setup

- `darkbloom cluster` setup is shorter and asks with lists: four steps (Connect, Pair, Choose a model, Start), one line
  for each thing that happened, and every choice (the pairing code, the model, a missing model's copy, the leader's
  menu) is a list moved with ↑↓ and taken with enter, as `darkbloom start` picks models; plain transcripts number the
  list and take one key. The last line of each screen is the one thing to do next.
- The model list shows only the models approved for clusters (GLM-5.3-Flash and Qwen3.8 27B) that the two Macs can
  serve, and a named model that is not approved is refused.
- The Mac you set up on leads and keeps leading: every plan puts rank 0 (the API and the coordinator's registration)
  on it, and before a plan exists it is the leader on identical Macs too.
- macOS's permissions are asked at stated moments on each Mac, with what to click: the cable's port and this
  terminal's Local Network access in Connect, Darkbloom's Local Network access right after the code is confirmed.
  Where macOS cannot show its password window (an SSH session), the setup runs the port's commands with sudo in that
  terminal instead of sending you to run a script.
- On the Mac that follows, `darkbloom cluster` shows the status and where to manage the cluster, with nothing to
  choose; both Macs say whether their window can be closed.
- `darkbloom doctor` includes the cluster's checks on a Mac paired for a cluster.
