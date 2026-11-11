### A GLM-5.3-Flash Mac no longer reads as full while it serves nothing

- A GLM-5.3-Flash Mac's heartbeat now reports as used only the requests it holds, as its own admission charges them. It used to report the memory its engine keeps after every request and reuses for the next, which grew to 90–99 % of the budget, so Darkbloom turned most GLM requests away while the Mac sat idle. A GLM Mac can now take as many requests at once as its memory admits.
- A GLM request waiting for another's prompt to finish is now counted once. It was counted twice on this Mac's own API, so a 256 GB M5 Ultra took two long requests at once instead of three.
