### Provider CI: submodules fetched in parallel

- The macOS CI jobs check out the submodules with `scripts/ci-checkout-submodules.py` instead of `actions/checkout`'s `submodules: recursive`. It fetches each submodule's recorded commit once, at depth 1 and in parallel, where `submodules: recursive` cloned each default branch and then fetched the recorded commit, one submodule after another. The same `git submodule sync` and `git submodule update --init --force --depth=1 --recursive` then check them out, so the checked-out files, pins and `.git/modules` layout are unchanged.
