### Two-Mac pairs: a "leader lost" stop on the Mac that follows says which one it was

- When the session on the Mac that follows ended as "leader lost", its `rank.log` and the incident it records said only that. They now say whether the leading Mac's process restarted, or whether this Mac's own session with the coordinator ended (and why: cancelled by the coordinator, its grant expired, its connection closed, its member stopping, and so on). Nothing else about the pair changes.
