import MLX

enum GemmaSmallGatherQMVCases {
    struct Case {
        let name: String, tokens: Int, ids: [UInt32]
        var uniqueExperts: Int { Set(ids).count }
    }
    static var all: [Case] {
        (1...3).flatMap { tokens in
            ["disjoint", "shared", "partial", "permuted"].map { name in
                var ids: [UInt32] = []
                for token in 0..<tokens {
                    for slot in 0..<8 {
                        let id: Int
                        switch name {
                        case "disjoint": id = token * 8 + slot
                        case "shared": id = 16 + slot
                        case "partial": id = slot < 4 ? slot : 8 + token * 4 + slot - 4
                        default: id = 16 + (slot + token * 3) % 8
                        }
                        ids.append(UInt32(id))
                    }
                }
                return Case(name: "t\(tokens)-\(name)", tokens: tokens, ids: ids)
            }
        }
    }
}
