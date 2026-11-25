Fixture-only successor for Swift6 warnings-as-errors: pass the actual completed group count to a parameterized exact13 assertion, avoiding the constant-folded unreachable else warning. Every existing assertion/group and all five runtime overlays remain unchanged. Preserve ea157 and root actual-1 compile failure. No author compilation or fixture execution.

Root command after physical retirement:
```
xcrun swiftc -swift-version 6 -warnings-as-errors -j 2 ../remote-assistant-fresh-guard-draft/Runtime/Gemma4BenchmarkGuardInvocation.swift GuardInvocationChecks.swift -o FRESH/GuardInvocationChecks
FRESH/GuardInvocationChecks
```
