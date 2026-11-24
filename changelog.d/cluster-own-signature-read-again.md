### A two-Mac pair sets itself up again after an update that lands while the app is still settling

- Right after an update installs Darkbloom, the app bundle can still change for some seconds after the new cluster service starts. If the service read its own code signature in that window, it refused every cluster helper ("could not read its own code signature") for the rest of its run, and the pair stayed stopped until it was started by hand.
- The provider now reads its own signature again at the next helper launch while that read fails, and keeps the first answer it can read. Every read still requires the file to match the running program and to carry this project's signature, so nothing weaker is accepted.
