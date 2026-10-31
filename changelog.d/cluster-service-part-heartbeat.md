### The cluster service is no longer restarted while its pair is registered

A pair registered with the coordinator could restart the cluster service of a Mac many times a day (about every 15 minutes on one DevNet leader: "heartbeat missing for 75 s while its process is alive"), and each restart dropped the pair for a short time. The Mac's part inherited the service's heartbeat file and wrote its own heartbeats into it, and the supervisor does not count a heartbeat from another process. The part now writes its heartbeats to a file of its own (`~/.darkbloom/cluster-setup/part-health.json`).
