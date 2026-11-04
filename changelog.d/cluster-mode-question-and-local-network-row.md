### Two-Mac cluster: the mode question shows what loads, and Local Network hints name the row macOS shows

- When you choose how both Macs split a model, each way now shows the split that loads, and the start loads exactly
  that plan. Before, with nothing serving, GLM-5.3-Flash's pipeline was offered as "this Mac 1 layer / the other Mac
  44 layers" and loaded as 44 / 1. A way chosen on the Mac that joined now loads too; before, the leading Mac loaded
  its own first choice.
- Each way also says how many requests it serves at once: "serves one request at a time" for GLM-5.3-Flash's
  pipeline, "serves up to 8 requests at once" for its tensor parallel. On a GLM-5.3-Flash pair, choose tensor
  parallel: through Darkbloom its pipeline turns every other request away as "at capacity".
- The Local Network hints on the setup screens, in `status` and `cluster status`, and in the log of the process that
  dials the other Mac name the row System Settings shows, "Darkbloom". The DevNet app's row has that name too, since
  both apps share one bundle ID. Where macOS never recorded an answer for the app and lists no row, the hints say to
  click Allow when macOS asks on that Mac's screen.
- The question recommends one way for these two Macs and says why: the only one that fits now, the one that serves
  more requests at once through Darkbloom, or the clearly faster one. It is the same on both Macs' screens, and Enter
  takes it. When nothing fits or nothing is known yet, it recommends none and says why.
- That recommendation is the question's first line and names the model, for example "Recommended for Gemma 4 26B on
  these two Macs: Tensor parallel", with the mode in bold in a colour terminal; in a narrow window the reason is
  shortened, never the names.
- `darkbloom uninstall` and `darkbloom cluster link --remove` undo every Thunderbolt port Darkbloom set up under one
  macOS approval, instead of stopping at "More than one port qualifies …; choose one". Each port's own network service
  is removed before the port goes back into its bridge (it used to end up in both), the removal stops at the first
  command that fails and says which ports are left, and an uninstall that already forgot the pairing says what is
  left and that running `darkbloom uninstall` again finishes it.
- On a Mac whose Thunderbolt ports start in the Thunderbolt Bridge, such as a MacBook, Darkbloom's network service is
  the port's only one, which macOS refuses to remove with its usual command. The removal now takes it out through
  macOS's network preferences, after checking its name and port, and setting up the cable port again reuses
  Darkbloom's existing service instead of removing and remaking it.
