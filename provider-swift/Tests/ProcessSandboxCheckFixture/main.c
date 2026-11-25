// Test-only: prints this process's `provider_sandbox_check_self()` answer, so
// `ProcessSandboxFixtureTests` can ask the production probe in a plain process
// and in one inside a minimal sandbox. Release builds name their products, so
// none builds or ships it.
#include <stdio.h>

#include "ProviderSandboxCheck.h"

int main(void) {
    printf("%d\n", provider_sandbox_check_self());
    return 0;
}
