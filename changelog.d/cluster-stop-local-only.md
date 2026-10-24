### Stop a cluster Mac whose peer is gone

`darkbloom cluster stop --local-only` stops only this Mac's cluster service and removes its login agent. It never asks the other Mac, for when that Mac is gone for good. Without the flag, a leader still drains the pair first and keeps its service when the member cannot acknowledge. The output says that the other Mac was not asked to stop.
