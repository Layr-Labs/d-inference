### Dev releases carry their cluster runtime facts

- A dev release now registers the cluster runtime facts of its final signed app (`cluster_runtime`): the digests of the cluster worker, placement tool, Metal library and paged-attention source, and for each model the build qualifies on a cluster, the digests of the capability its own worker describes. The dev coordinator can derive its cluster approvals from them. Prod and staging releases are unchanged.
- `darkbloom cluster runtime-facts` (hidden) prints these facts for an app bundle and the models given to it.
