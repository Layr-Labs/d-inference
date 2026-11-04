### `darkbloom cluster` on a set-up pair says what is what

- The opening names both Macs and the cable ("This Mac (Studio A) leads · the
  other Mac (Apple M3 Ultra, 256 GB) follows · cable ready"), then the status
  as the ✓/✗ outcome block, on the leader and on the Mac that follows.
- The leader says how the pair works and gives one line per item saying what
  it does: Change model, Test a response, Stop serving, Serve locally only or
  through Darkbloom, Start over, Quit (and Check memory is freed once stopped).
- Change model marks the model serving now, gives each mode with the speed
  this pair served it at or "not measured on these Macs yet", asks how both
  Macs split a model that runs more than one way (the fastest measured first,
  tensor parallel or pipeline one keypress away, on mixed Macs too), then asks
  once before the running model stops, and says when it stopped.
- The Mac that follows says that its part runs by itself and which command to
  run on the leading Mac.
- A fresh setup opens with what it will ask and how long it takes.
- A stopped pair offers **Start <model> again** first: the last model, in the mode it served in, without the list.
  Switching how a stopped pair serves offers to start it that way.
- **Serve through Darkbloom** checks both Macs' logins before the local API stops; **Stop serving** asks once on a pair
  served through Darkbloom.
- Outside the first setup the steps say **Change model** (or **Choose a model**) and **Start**, not "3/4" and "4/4".
