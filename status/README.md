# Darkbloom status placeholder

This standalone static page is the proposed temporary replacement for
`https://status.darkbloom.dev/`. Its only visible message is:

> The status page will return in the future.

Preview locally from the repository root:

```sh
python3 -m http.server 3010 --bind 127.0.0.1 --directory status
```

Open `http://127.0.0.1:3010/`. No build step, dependencies, JavaScript, or
external assets are required.

The existing public page is hosted by Instatus; its content and configuration
are outside this repository. This directory does not change that page or delete
its incident history, components, or monitors. Publishing the placeholder and
switching the status domain require a separate hosting change. Keep the Instatus
page and its content intact so they can be restored later.
