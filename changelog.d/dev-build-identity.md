### Dev provider builds have their own identity

- A dev build is now `darkbloom-dev` in `Darkbloom Dev.app`, installed in `~/.darkbloom-dev` with its configuration in `~/.config/darkbloom-dev`. It uses the LaunchAgent labels `io.darkbloom.provider.dev` and `io.darkbloom.watchdog.dev`, the default backend port `8101`, its own log subsystems and its own keychain items. A dev provider and a production provider can run on the same Mac.
- The installer selects the dev identity when the release version contains `-dev.`. Production names, paths, port, labels and keychain items are unchanged.
- An earlier dev install in `~/.darkbloom` cannot update to a dev build with the new names. Install the dev provider again with the dev `install.sh`.
