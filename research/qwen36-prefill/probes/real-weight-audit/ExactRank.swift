import CryptoKit
import Foundation

struct RankCertificate: Sendable {
    let status: String
    let prime: Int?
    let exactLowerBound: Int
    let exactUpperBound: Int
    let requiredToRuleOut39Percent: Int
    let target: Int
    let attempt: Int?
    let selectedRowCount: Int
    let selectedColumnCount: Int
    let minorRowIndexSHA256: String?
    let minorColumnIndexSHA256: String?
    let minorFieldValueSHA256: String?
    let macDeletionUpperBound: Double

    var rulesOut39Percent: Bool {
        exactLowerBound >= requiredToRuleOut39Percent
    }
}

private struct FieldRankResult {
    let rank: Int
    let pivotSourceRows: [Int]
    let pivotColumns: [Int]
}

func rankRequiredToRuleOut39Percent(rows: Int, columns: Int) -> Int {
    // A rank-r factorization uses r*(N+K) MACs instead of N*K. Any exact
    // factorization deleting at least 39% therefore has
    // r <= floor(61*N*K / (100*(N+K))). Proving one rank above that cutoff
    // is sufficient; no probabilistic inference is involved.
    let numerator = 61 * rows * columns
    let denominator = 100 * (rows + columns)
    return numerator / denominator + 1
}

func certifyExactRankLowerBound(
    tensor: QuantizedTensor,
    matrix: Int,
    nonzeroRows: [Bool],
    nonzeroColumns: [Bool],
    uniqueNonzeroRowCount: Int,
    uniqueNonzeroColumnCount: Int
) -> RankCertificate {
    let required = rankRequiredToRuleOut39Percent(
        rows: tensor.rows,
        columns: tensor.columns
    )
    let exactUpperBound = min(uniqueNonzeroRowCount, uniqueNonzeroColumnCount)
    guard exactUpperBound >= required else {
        return RankCertificate(
            status: "upper-bound-below-required",
            prime: nil,
            exactLowerBound: 0,
            exactUpperBound: exactUpperBound,
            requiredToRuleOut39Percent: required,
            target: required,
            attempt: nil,
            selectedRowCount: 0,
            selectedColumnCount: 0,
            minorRowIndexSHA256: nil,
            minorColumnIndexSHA256: nil,
            minorFieldValueSHA256: nil,
            macDeletionUpperBound: 1
        )
    }

    // The extra 64 ranks create margin above the exact 39% cutoff where the
    // matrix supports it. Sparse layer-0 expert matrices naturally cap this
    // target at their exact nonzero/unique-row upper bound.
    let target = min(exactUpperBound, required + 64)
    let baseSeed = stableSeed("\(tensor.baseName)#\(matrix)")

    for attempt in 0..<4 {
        let attemptSeed = splitMix64(baseSeed &+ UInt64(attempt))
        let selectedRows = cyclicSelection(
            eligible: nonzeroRows,
            desired: min(exactUpperBound, target + 64),
            seed: attemptSeed
        )
        let selectedColumns = cyclicSelection(
            eligible: nonzeroColumns,
            desired: min(uniqueNonzeroColumnCount, target + 64),
            seed: splitMix64(attemptSeed)
        )
        let ternary = buildGF3Rows(
            tensor: tensor,
            matrix: matrix,
            rows: selectedRows,
            columns: selectedColumns
        )
        let result = rankGF3(
            ones: ternary.ones,
            twos: ternary.twos,
            rowCount: selectedRows.count,
            columnCount: selectedColumns.count,
            stopAt: target
        )
        if result.rank >= target {
            return makeCertificate(
                tensor: tensor,
                matrix: matrix,
                prime: 3,
                result: result,
                selectedRows: selectedRows,
                selectedColumns: selectedColumns,
                exactUpperBound: exactUpperBound,
                required: required,
                target: target,
                attempt: attempt
            )
        }
    }

    // A rationally nonsingular minor can vanish modulo 3. Modulo 5 is an
    // independent exact field, not a floating fallback. It is only paid for
    // when every deterministic GF(3) selection misses the requested bound.
    for attempt in 0..<2 {
        let attemptSeed = splitMix64(baseSeed &+ 0x5000 &+ UInt64(attempt))
        let selectedRows = cyclicSelection(
            eligible: nonzeroRows,
            desired: min(exactUpperBound, target + 32),
            seed: attemptSeed
        )
        let selectedColumns = cyclicSelection(
            eligible: nonzeroColumns,
            desired: min(uniqueNonzeroColumnCount, target + 32),
            seed: splitMix64(attemptSeed)
        )
        let fieldRows = buildPrimeRows(
            tensor: tensor,
            matrix: matrix,
            rows: selectedRows,
            columns: selectedColumns,
            prime: 5
        )
        let result = rankSmallPrime(
            values: fieldRows,
            rowCount: selectedRows.count,
            columnCount: selectedColumns.count,
            prime: 5,
            stopAt: target
        )
        if result.rank >= target {
            return makeCertificate(
                tensor: tensor,
                matrix: matrix,
                prime: 5,
                result: result,
                selectedRows: selectedRows,
                selectedColumns: selectedColumns,
                exactUpperBound: exactUpperBound,
                required: required,
                target: target,
                attempt: 4 + attempt
            )
        }
    }

    return RankCertificate(
        status: "no-minor-found-within-labelled-search",
        prime: nil,
        exactLowerBound: 0,
        exactUpperBound: exactUpperBound,
        requiredToRuleOut39Percent: required,
        target: target,
        attempt: nil,
        selectedRowCount: 0,
        selectedColumnCount: 0,
        minorRowIndexSHA256: nil,
        minorColumnIndexSHA256: nil,
        minorFieldValueSHA256: nil,
        macDeletionUpperBound: 1
    )
}

private func makeCertificate(
    tensor: QuantizedTensor,
    matrix: Int,
    prime: Int,
    result: FieldRankResult,
    selectedRows: [Int],
    selectedColumns: [Int],
    exactUpperBound: Int,
    required: Int,
    target: Int,
    attempt: Int
) -> RankCertificate {
    let localRows = Array(result.pivotSourceRows.prefix(target))
    let localColumns = Array(result.pivotColumns.prefix(target))
    let minorRows = localRows.map { selectedRows[$0] }
    let minorColumns = localColumns.map { selectedColumns[$0] }

    var fieldDigest = SHA256()
    for row in minorRows {
        for column in minorColumns {
            let value = bf16ModPrime(
                tensor.decodedBits(matrix: matrix, row: row, column: column),
                prime: prime
            )
            withUnsafeBytes(of: value) { fieldDigest.update(bufferPointer: $0) }
        }
    }

    let lowerBound = target
    let baseline = Double(tensor.rows) * Double(tensor.columns)
    let factorMACs = Double(lowerBound) * Double(tensor.rows + tensor.columns)
    let deletionUpperBound = max(0, 1 - factorMACs / baseline)
    return RankCertificate(
        status: lowerBound == exactUpperBound ? "exact-rank" : "exact-lower-bound",
        prime: prime,
        exactLowerBound: lowerBound,
        exactUpperBound: exactUpperBound,
        requiredToRuleOut39Percent: required,
        target: target,
        attempt: attempt,
        selectedRowCount: selectedRows.count,
        selectedColumnCount: selectedColumns.count,
        minorRowIndexSHA256: sha256Integers(minorRows),
        minorColumnIndexSHA256: sha256Integers(minorColumns),
        minorFieldValueSHA256: fieldDigest.finalize().hexString,
        macDeletionUpperBound: deletionUpperBound
    )
}

private func cyclicSelection(
    eligible: [Bool],
    desired: Int,
    seed: UInt64
) -> [Int] {
    guard desired > 0, !eligible.isEmpty else { return [] }
    let count = eligible.count
    var step = Int((seed >> 32) % UInt64(count))
    if step == 0 { step = 1 }
    while greatestCommonDivisor(step, count) != 1 {
        step += 1
        if step == count { step = 1 }
    }
    var index = Int(seed % UInt64(count))
    var result: [Int] = []
    result.reserveCapacity(desired)
    for _ in 0..<count {
        if eligible[index] {
            result.append(index)
            if result.count == desired { break }
        }
        index += step
        if index >= count { index -= count }
    }
    return result
}

private func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
    var a = lhs
    var b = rhs
    while b != 0 {
        (a, b) = (b, a % b)
    }
    return a
}

private func stableSeed(_ string: String) -> UInt64 {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        value ^= UInt64(byte)
        value &*= 0x0000_0100_0000_01b3
    }
    return value
}

@inline(__always)
private func splitMix64(_ input: UInt64) -> UInt64 {
    var value = input &+ 0x9e37_79b9_7f4a_7c15
    value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
    value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
    return value ^ (value >> 31)
}

private struct TernaryRows {
    let ones: [UInt64]
    let twos: [UInt64]
}

private func buildGF3Rows(
    tensor: QuantizedTensor,
    matrix: Int,
    rows: [Int],
    columns: [Int]
) -> TernaryRows {
    let words = (columns.count + 63) / 64
    var ones = [UInt64](repeating: 0, count: rows.count * words)
    var twos = [UInt64](repeating: 0, count: rows.count * words)
    for (localRow, row) in rows.enumerated() {
        let base = localRow * words
        for (localColumn, column) in columns.enumerated() {
            let value = bf16ModPrime(
                tensor.decodedBits(matrix: matrix, row: row, column: column),
                prime: 3
            )
            let word = base + localColumn / 64
            let bit = UInt64(1) << UInt64(localColumn & 63)
            if value == 1 {
                ones[word] |= bit
            } else if value == 2 {
                twos[word] |= bit
            }
        }
    }
    return TernaryRows(ones: ones, twos: twos)
}

private func rankGF3(
    ones: [UInt64],
    twos: [UInt64],
    rowCount: Int,
    columnCount: Int,
    stopAt: Int
) -> FieldRankResult {
    let words = (columnCount + 63) / 64
    var basisOne = [UInt64](repeating: 0, count: columnCount * words)
    var basisTwo = [UInt64](repeating: 0, count: columnCount * words)
    var basisSource = [Int](repeating: -1, count: columnCount)
    var pivots: [Int] = []
    pivots.reserveCapacity(stopAt)

    var rowOne = [UInt64](repeating: 0, count: words)
    var rowTwo = [UInt64](repeating: 0, count: words)
    for sourceRow in 0..<rowCount {
        let sourceBase = sourceRow * words
        for word in 0..<words {
            rowOne[word] = ones[sourceBase + word]
            rowTwo[word] = twos[sourceBase + word]
        }

        for column in 0..<columnCount {
            let wordIndex = column / 64
            let bit = UInt64(1) << UInt64(column & 63)
            let factor: UInt8
            if rowOne[wordIndex] & bit != 0 {
                factor = 1
            } else if rowTwo[wordIndex] & bit != 0 {
                factor = 2
            } else {
                continue
            }

            if basisSource[column] < 0 {
                if factor == 2 {
                    swap(&rowOne, &rowTwo)
                }
                let basisBase = column * words
                for word in wordIndex..<words {
                    basisOne[basisBase + word] = rowOne[word]
                    basisTwo[basisBase + word] = rowTwo[word]
                }
                basisSource[column] = sourceRow
                pivots.append(column)
                if pivots.count == stopAt {
                    return FieldRankResult(
                        rank: pivots.count,
                        pivotSourceRows: pivots.map { basisSource[$0] },
                        pivotColumns: pivots
                    )
                }
                break
            }

            let basisBase = column * words
            for word in wordIndex..<words {
                let a1 = rowOne[word]
                let a2 = rowTwo[word]
                let b1 = basisOne[basisBase + word]
                let b2 = basisTwo[basisBase + word]
                let a0 = ~(a1 | a2)
                let b0 = ~(b1 | b2)
                if factor == 1 {
                    // a - b == a + (-b); negation swaps the one/two planes.
                    rowOne[word] = (a0 & b2) | (a1 & b0) | (a2 & b1)
                    rowTwo[word] = (a0 & b1) | (a2 & b0) | (a1 & b2)
                } else {
                    // a - 2b == a + b in GF(3).
                    rowOne[word] = (a0 & b1) | (a1 & b0) | (a2 & b2)
                    rowTwo[word] = (a0 & b2) | (a2 & b0) | (a1 & b1)
                }
            }
        }
    }
    return FieldRankResult(
        rank: pivots.count,
        pivotSourceRows: pivots.map { basisSource[$0] },
        pivotColumns: pivots
    )
}

private func buildPrimeRows(
    tensor: QuantizedTensor,
    matrix: Int,
    rows: [Int],
    columns: [Int],
    prime: Int
) -> [UInt8] {
    var values = [UInt8](repeating: 0, count: rows.count * columns.count)
    for (localRow, row) in rows.enumerated() {
        let base = localRow * columns.count
        for (localColumn, column) in columns.enumerated() {
            values[base + localColumn] = bf16ModPrime(
                tensor.decodedBits(matrix: matrix, row: row, column: column),
                prime: prime
            )
        }
    }
    return values
}

private func rankSmallPrime(
    values: [UInt8],
    rowCount: Int,
    columnCount: Int,
    prime: Int,
    stopAt: Int
) -> FieldRankResult {
    var basis = [UInt8](repeating: 0, count: columnCount * columnCount)
    var basisSource = [Int](repeating: -1, count: columnCount)
    var pivots: [Int] = []
    var row = [UInt8](repeating: 0, count: columnCount)
    let inverses: [UInt8]
    switch prime {
    case 5:
        inverses = [0, 1, 3, 2, 4]
    default:
        preconditionFailure("unsupported small prime")
    }

    for sourceRow in 0..<rowCount {
        let sourceBase = sourceRow * columnCount
        for column in 0..<columnCount {
            row[column] = values[sourceBase + column]
        }
        for column in 0..<columnCount {
            let factor = Int(row[column])
            if factor == 0 { continue }
            let basisBase = column * columnCount
            if basisSource[column] < 0 {
                let inverse = Int(inverses[factor])
                for tail in column..<columnCount {
                    row[tail] = UInt8((Int(row[tail]) * inverse) % prime)
                    basis[basisBase + tail] = row[tail]
                }
                basisSource[column] = sourceRow
                pivots.append(column)
                if pivots.count == stopAt {
                    return FieldRankResult(
                        rank: pivots.count,
                        pivotSourceRows: pivots.map { basisSource[$0] },
                        pivotColumns: pivots
                    )
                }
                break
            }
            for tail in column..<columnCount {
                let reduced =
                    Int(row[tail]) - factor * Int(basis[basisBase + tail])
                row[tail] = UInt8((reduced % prime + prime) % prime)
            }
        }
    }
    return FieldRankResult(
        rank: pivots.count,
        pivotSourceRows: pivots.map { basisSource[$0] },
        pivotColumns: pivots
    )
}

@inline(__always)
func bf16ModPrime(_ bits: UInt16, prime: Int) -> UInt8 {
    let exponentBits = Int((bits >> 7) & 0xff)
    let fraction = Int(bits & 0x7f)
    precondition(exponentBits != 0xff, "non-finite BF16 has no finite-field image")
    if exponentBits == 0 && fraction == 0 { return 0 }

    let mantissa: Int
    let binaryExponent: Int
    if exponentBits == 0 {
        mantissa = fraction
        binaryExponent = -133
    } else {
        mantissa = 128 + fraction
        binaryExponent = exponentBits - 134
    }
    var value = mantissa % prime
    let powerOfTwo: Int
    switch prime {
    case 3:
        powerOfTwo = binaryExponent & 1 == 0 ? 1 : 2
    case 5:
        let residue = (binaryExponent % 4 + 4) % 4
        powerOfTwo = [1, 2, 4, 3][residue]
    default:
        preconditionFailure("unsupported certificate prime \(prime)")
    }
    value = value * powerOfTwo % prime
    if bits & 0x8000 != 0, value != 0 {
        value = prime - value
    }
    return UInt8(value)
}

private func sha256Integers(_ values: [Int]) -> String {
    var digest = SHA256()
    for value in values {
        var littleEndian = UInt64(value).littleEndian
        withUnsafeBytes(of: &littleEndian) { digest.update(bufferPointer: $0) }
    }
    return digest.finalize().hexString
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

func runExactRankSelfTests() throws {
    let one = floatToBF16RoundToNearestEven(1)
    let two = floatToBF16RoundToNearestEven(2)
    let minusOne = floatToBF16RoundToNearestEven(-1)
    let half = floatToBF16RoundToNearestEven(0.5)
    guard
        bf16ModPrime(one, prime: 3) == 1,
        bf16ModPrime(two, prime: 3) == 2,
        bf16ModPrime(minusOne, prime: 3) == 2,
        bf16ModPrime(half, prime: 3) == 2
    else {
        throw AuditError.invalid("BF16-to-GF(3) self-test failed")
    }

    // diag(1, 1, 3) has rank two over GF(3) and rank three over GF(5).
    let values: [UInt8] = [1, 0, 0, 0, 1, 0, 0, 0, 3]
    var ones = [UInt64](repeating: 0, count: 3)
    var twos = [UInt64](repeating: 0, count: 3)
    for row in 0..<3 {
        for column in 0..<3 {
            let bit = UInt64(1) << UInt64(column)
            if values[row * 3 + column] == 1 {
                ones[row] |= bit
            } else if values[row * 3 + column] == 2 {
                twos[row] |= bit
            }
        }
    }
    let gf3 = rankGF3(
        ones: ones,
        twos: twos,
        rowCount: 3,
        columnCount: 3,
        stopAt: 3
    )
    let gf5 = rankSmallPrime(
        values: values,
        rowCount: 3,
        columnCount: 3,
        prime: 5,
        stopAt: 3
    )
    guard gf3.rank == 2, gf5.rank == 3 else {
        throw AuditError.invalid("finite-field elimination self-test failed")
    }
}
