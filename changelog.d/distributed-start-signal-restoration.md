### Distributed startup signal restoration

Distributed startup restores both SIGTERM and SIGINT dispositions, including
handler flags and blocked signals, even when one signal was already ignored.
A termination request received before serving starts remains latched.
