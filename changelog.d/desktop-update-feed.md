### Desktop app updates itself

Desktop releases now embed an update feed: Release `desktop-latest`, whose
assets each `desktop-vX.Y.Z` release replaces with its zip, blockmap,
`latest-mac.yml` and a version-less `Darkbloom-arm64.dmg`. Installed apps check
it at launch and every 4 hours, download in the background and install on quit.
A release build without a feed is refused, since the feed is fixed at build
time. The workflow verifies the embedded feed URL and that `latest-mac.yml`
matches the published files.
