### A pair on two different DevNet builds says which Mac to update

- When only one Mac of a pair was updated, `darkbloom status` and `darkbloom cluster` name the versions and the Mac that needs `darkbloom update`. Between two DevNet builds (`0.10.13-dev.branch.N`) the versions were not compared, so the updated Mac's status only repeated "this Mac's part ended (… Installed input identity or SHA-256 differs)". They compare as semantic versions now; release versions are unchanged.
