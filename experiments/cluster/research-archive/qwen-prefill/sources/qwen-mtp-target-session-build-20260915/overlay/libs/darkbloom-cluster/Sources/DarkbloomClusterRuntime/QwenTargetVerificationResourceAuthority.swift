/// Closed constructors. Ordinary execution can only select the existing sealed
/// registered profile. The other case does not exist in product compilation.
enum QwenTargetVerificationResourceAuthority {
    case registered(QwenTargetVerificationResources)
    #if QWEN_TARGET_TINY_FIXTURE
    case tiny(QwenTinyTargetVerificationResources)
    #endif

    var budget: QwenTargetVerificationBudget {
        switch self {
        case .registered(let value): value.budget
        #if QWEN_TARGET_TINY_FIXTURE
        case .tiny(let value): value.budget
        #endif
        }
    }

    func requireLive(ownerCheck: (QwenTargetVerificationBudget) throws -> Void) throws {
        switch self {
        case .registered(let value): try value.requireLive(ownerCheck: ownerCheck)
        #if QWEN_TARGET_TINY_FIXTURE
        case .tiny(let value): try value.requireLive(ownerCheck: ownerCheck)
        #endif
        }
    }
}
