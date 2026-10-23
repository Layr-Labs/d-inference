### Faster GLM-5.3-Flash starts

- The managed GLM load's own SHA-256 check of every manifest file now is the published weight hash. Coordinator and local loads no longer read all 182 GB again in a separate weight-hash pass before and after loading, about 50 s per start on an M5 Ultra. Every file is still verified against the catalog manifest before the model serves, and a changed file identity during the load still fails it.
- A coordinator-mode start registers GLM's last fully verified hash while every weight file keeps its device, inode, size and modification and status-change times, instead of hashing 182 GB before the load reads them again; about 25 s more per restart. Any changed file is hashed in full. The record is `~/.darkbloom/verified-weights.json`, owner-only.
- The load logs its phases: `GLM load glm-5.3-flash: all 42 manifest files SHA-256 verified before serving; auxiliary verification …, core verification …, tensors and construction …, total …`.
