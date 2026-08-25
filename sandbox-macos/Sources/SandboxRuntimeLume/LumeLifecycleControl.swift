import SandboxRuntime

enum LumeLifecycleControl {
    static let environmentVariable =
        "DARKBLOOM_LUME_LIFECYCLE_FD"

    static let processControl = SandboxCooperativeProcessControl(
        environmentVariable: environmentVariable
    )
}
