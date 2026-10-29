### Cluster planning accepts a DevNet app's install path

- Planning a two-Mac cluster with a DevNet build no longer fails every model with "Peer installation paths must be absolute and shell-safe". The DevNet app is installed as `Darkbloom Dev.app`; a saved cluster setup now accepts a space in the installed owner and worker executables, the model directory, and the native member's metallib and resource library.
- Shell syntax, relative paths and `..` are still refused, and the developer SSH route still checks every path it puts in a remote command.
