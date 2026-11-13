### Faster recovery from a dead coordinator link

- **The provider now finds a silent coordinator link in 6 to 8 s and reconnects at once:** it pings every 2 s and declares the link dead when no frame (pong, ping or message) comes in for more than 6 s. Before, a link that died with no reset and no close frame, for example on a coordinator node restart, took up to 40 s to notice.
- After a session that stayed open for 60 s or more, the first reconnect waits 0 to 0.25 s instead of 0.5 to 1 s; repeated failures still back off as before.
- A busy stream never trips the bound, because every inbound frame counts. A Mac that slept for 30 s or more reconnects once at wake, as before; a shorter delay of the ping timer is not counted as missed pongs.
