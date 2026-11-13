// Copyright © 2026 Eigen Labs.

/// A validated family control, carried separately from the client's wire request.
struct NativeReasoningBudget: Sendable, Equatable {
    enum Family: Sendable { case nemotronSuper, mimoV26 }
    let maximumTokens: Int
    let family: Family
}
