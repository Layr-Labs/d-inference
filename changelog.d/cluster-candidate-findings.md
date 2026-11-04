### Two-Mac cluster: Serve locally only starts the faster local plan, and a closing link names the other Mac

- Choosing **Serve locally only** at the first setup's login check now starts the local plan: the model is planned again
  for serving locally before anything starts, so Qwen 3.8 27B in tensor parallel keeps the speculative assistant that
  only local serving uses (measured on one pair: 15.7 tok/s without it, 36–39 tok/s with it).
- When a part keeps ending because the link to the other Mac keeps closing, the ✗ says so and names the other Mac's side
  ("the other Mac's worker ended or the cable dropped") instead of blaming this Mac and calling the other "running, no
  error reported"; the ✗ title no longer begins with "starting; ".
- The DevNet app's cluster screens and `status` name its own command (`darkbloom-dev …`), not the production
  `darkbloom`.
- The mode you choose for a model is now the one that loads, also for GLM-5.3-Flash. When a part keeps ending, the
  message names the Mac whose worker actually stopped, this Mac's included (or says it can't tell), gives the other
  Mac's own reason when it can't connect (for example, macOS blocking its local network access), and no longer shows a
  planned model switch as a crash. The DevNet app names its own command in more messages.
- When macOS's Local Network setting keeps a Mac's Darkbloom app from reaching the other Mac, every screen now says so
  and what to do on that Mac (turn on Darkbloom under Privacy & Security → Local Network, through Screen Sharing on a Mac
  with no display), instead of "the other Mac did not answer". Retry starts a stopped pair again, q leaves a start's wait
  at once, and the joining Mac's window shows how the leading Mac's start is going.
- The Local Network ✗ no longer ends with a line that repeated its instruction and was cut off mid-sentence, and a ✗
  line too long for the screen is cut at a word and marked with "…". In the DevNet app, the pairing screen's firewall
  hint and its line about a reinstall name Darkbloom Dev.
- While a model serves, the question of how both Macs split a model says the split is decided when it loads, instead
  of offering one that wouldn't load; one layer reads "1 layer". The joining Mac's last lines say whether it serves
  again after a restart as its cluster service stands when they're shown.
- The card after a start says "Starts by itself at login on both Macs." only when the cluster service on both Macs
  does; otherwise it names the Mac where it doesn't, or says the other Mac doesn't say (an older Darkbloom there).
