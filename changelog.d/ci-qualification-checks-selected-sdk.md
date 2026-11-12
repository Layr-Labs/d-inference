### CI: the cluster qualification checks build with the job's selected Xcode

- `libs/darkbloom-cluster-worker/Tests/QualificationChecks/run.sh` now uses the Xcode and SDK the job's toolchain step selected (`PROVIDER_SDKROOT`), so it no longer fails on a runner whose default developer directory is the command-line tools (`SDK "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" cannot be located`). Local runs keep `xcrun`'s own selection. CI only; no provider behaviour changes.
