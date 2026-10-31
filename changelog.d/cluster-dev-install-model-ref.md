### Cluster setup finds models a dev install downloaded

- `darkbloom-dev cluster` (and a staging install's) lists and uses the models that install downloaded. The cluster's model lookup read only production's `refs/main`, while a dev or staging install records its downloads under its own ref (`refs/darkbloom-dev`), so on a Mac with only a dev install the leader's download step failed with "downloaded, but the product's model store does not list it". It now reads the install's own ref, then production's, as single-Mac model discovery does.
