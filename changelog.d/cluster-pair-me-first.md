### Me first for a pair: Darkbloom pauses while you use the pair

- While you use a pair through its leader's local API, the pair takes no new Darkbloom requests. It takes them again
  two minutes after your last request ends (`[local] me_first_idle_minutes`). `[local] me_first = false` keeps today's
  shared serving.
- Darkbloom requests already running finish, and nothing is cut. A request that races the pause goes to another Mac.
  The pair keeps its session and its loaded model.
- The leader decides for the pair: its heartbeat says `draining` with `busy_reason: "owner"`, which takes the whole
  pair out of routing, your own `self` and `prefer` requests included. The other members don't change, and nothing
  assumes two Macs.
- The pair's base reward while it is paused depends on the coordinator. From
  [darkbloom-platform#709](https://github.com/Layr-Labs/darkbloom-platform/pull/709) on, the pair keeps it, as a single
  Mac does. On coordinators before #709, both Macs lose it for the pause plus the idle minutes, as for any pair drain.
- It costs next to nothing: one heartbeat when the pause begins and one when it ends, an O(1) update per local
  request, and an idle check on the member's existing 5-second beat.
- `darkbloom cluster` starts the leader's local API when you choose **Both, me first** for the pair.
