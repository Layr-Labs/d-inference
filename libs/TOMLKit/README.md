# TOMLKit (vendored)

A copy of [TOMLKit](https://github.com/LebJe/TOMLKit) 0.6.0, the library the provider reads and writes
`provider.toml` with, changed only so that it frees what it allocates. `provider-swift/Package.swift`
builds it from this directory instead of fetching the release.

| | |
|---|---|
| Upstream | [LebJe/TOMLKit](https://github.com/LebJe/TOMLKit/tree/ec6198d37d495efc6acd4dffbd262cdca7ff9b3f), tag `0.6.0`, commit `ec6198d37d495efc6acd4dffbd262cdca7ff9b3f`: the pin `provider-swift/Package.resolved` held before. No later release exists, and upstream `main` (`a6d921109837a16b9a63f83b32acad3774dfa752`) still frees nothing |
| Copied | `Sources/CTOML`, `Sources/TOMLKit` (without the `TOMLKit.docc` catalog) and `LICENSE`. `Package.swift` is upstream's `Package@swift-5.5.swift`, the manifest SwiftPM used, with only the library targets: no test target, Checkit or DocC plugin |
| Parser | `Sources/CTOML/Sources/toml.hpp` is [toml++](https://github.com/marzer/tomlplusplus) v3.4.0, unmodified (SHA-256 `6b5172ad4dd6519aec67b919181fa7a38a2234131e5b2afa232dfe444819783e`) |
| Licenses | TOMLKit: MIT, copyright (c) 2024 Jeff Lebrun, retained unmodified in [LICENSE](LICENSE) (SHA-256 `bccd5fe8b98c6caede07def6c03f55877416ec40ea5fcd18e668b5c6fbb10abe`) and in each source header. toml++: MIT, copyright (c) Mark Gillard, retained in the header of `toml.hpp` |

## The change

TOMLKit 0.6.0 never frees anything it allocates: not the C++ tree each `TOMLTable(string:)` parses,
not the nodes it makes for Swift values, and not the `malloc`ed buffers its value reads and
conversions return. Every parse stays in memory for the life of the process
([upstream issue 26](https://github.com/LebJe/TOMLKit/issues/26), open since January 2024). A
`deinit` alone would not do: a table's node is also referred to by the values and nested tables read
from it, which can outlive the table.

- `TOMLNodeOwner` (`Sources/TOMLKit/TOMLNodeOwner.swift`, new) owns one tree root the bridge allocated
  (`tableCreate`, `tableCreateFromString`, `arrayCreate`, `copyNode`, the `nodeFrom` value functions)
  and deletes it, with the new `nodeDelete`, when it is released. Every `TOMLTable`, `TOMLArray` and
  `TOMLValue` holds the owner of the tree its node is in; a value or nested table read from a table or
  an array shares that tree's owner. A nested node is never deleted on its own, and a value read from a
  table stays valid after the table itself is gone.
- The bridge's `malloc`ed buffers are freed once Swift has copied them: the value reads (`nodeAs`,
  with the new `dateTimeFree` for a date-time and its offset), `keys`, `values`, `convert(to:)`, the
  `debugDescription`s, and a parse error's description.
- `TOMLDateTime` hands its offset to the bridge from storage that lasts for the call
  (`withCTOMLDateTime`) instead of allocating it.

Changed files: `Sources/CTOML/include/CTOML/CTOML.h`, `Sources/CTOML/Sources/Node.cpp`, and under
`Sources/TOMLKit`: `TOMLNodeOwner.swift` (new), `TOMLValue/TOMLValue.swift`,
`TOMLValue/TOMLValue+Initializers.swift`, and in `TOML Data Types`: `TOMLValueConvertible.swift`,
`TOMLDate&Time&DateTime.swift`, `TOMLTable/TOMLTable.swift`, `TOMLTable/TOMLTable+CollectionFunctions.swift`,
`TOMLArray/TOMLArray.swift`, `TOMLArray/TOMLArray+CollectionConformance.swift`. Every other copied
source file, and `LICENSE`, is byte-identical to upstream.

The public API, toml++ and TOMLKit's parsing, comparison and formatting are unchanged. Inserting a
table, array or value copies it into the destination, so no node ever moves between trees. Two
hazards of 0.6.0 are unchanged too:

- An edit that replaces or removes a nested node (assignment, `remove(at:)`, `clear()`, and
  `TOMLArray.replaceSubrange` when it grows the array, which overwrites elements before it reads
  them) deletes that node, so a wrapper still referring to it must not be used afterwards.
- toml++ v3.4.0 fails an `assert` in `parse_key` on a table header that starts `[[[` or `[[ [`, and
  SwiftPM keeps `assert` in release builds, so parsing such a file aborts the process. toml++ fixed
  this after v3.4.0 (marzer/tomlplusplus#301), in no release yet.

## Checks

`provider-swift/Tests/ProviderCoreTests/Config/TOMLParseMemoryTests.swift` parses, decodes and
re-saves a provider configuration about 2,000 times each and requires the bytes in use to stay flat; it
also checks that values, conversions and parse errors are those 0.6.0 produced. When this copy changed,
upstream's own test suite (`Tests/TOMLKitTests`, without its Checkit call) passed against it, also
under AddressSanitizer, and macOS `leaks` found no leak in a run that exercised every accessor.

To move to a newer release, copy the same paths from it, reapply this change, and run those checks.
