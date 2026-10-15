import DarkbloomClusterProtocol

extension QwenResidentAdapterDefinition {
    /// A synthetic valid vocabulary ID, not user text or a reusable prefix.
    /// One configured full chunk plus two selections exercises initial prefill
    /// and one decode input. It does not cover every long-context kernel shape.
    static var startupPreparation: ClusterRuntimeStartupPreparation {
        .init(tokenPattern: [1], outputCount: 2)
    }
}
