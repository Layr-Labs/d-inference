### Cluster setup names "this Mac" and "the other Mac"

- `darkbloom cluster` names the two Macs from the screen that shows them: "this Mac" and "the other Mac (Apple M5 Ultra, 256 GB)" in pairing, the machine list, each model's split ("this Mac 50% / the other Mac 50%"), the serving and API lines, status, teardown checks and copies. Two identical Macs were both "Apple M5 Ultra, 256 GB", and the API line did not say it was on the other Mac. Answers the leader gives to the other Mac are worded for that Mac's screen.
- The Mac that joins a waiting leader stops after pairing, also when started with `darkbloom cluster local`; it says to run that on the Mac that leads instead of showing a second model list.
- A model one Mac holds twice (the catalog's download beside the cluster's own copy of the same files) is listed once, and a supported model is never listed as "not supported on a cluster yet" for a copy the cluster worker does not take.
