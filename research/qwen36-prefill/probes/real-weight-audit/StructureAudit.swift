import CryptoKit
import Dispatch
import Foundation

struct DuplicateClassSample: Sendable {
    let hash: String
    let count: Int
}

struct DuplicateStats: Sendable {
    let totalItems: Int
    let uniqueItems: Int
    let duplicateItems: Int
    let duplicateClasses: Int
    let maximumMultiplicity: Int
    let unequalHashCollisions: Int
    let classDigestSHA256: String
    let classSamples: [DuplicateClassSample]
    let representativeMask: [Bool]?
}

struct MatrixAudit: Sendable {
    let matrixIndex: Int
    let codeHistogram: [UInt64]
    let scaleHistogram: [UInt16: UInt64]
    let biasHistogram: [UInt16: UInt64]
    let decodedZeroCount: Int64
    let decodedPositiveZeroCount: Int64
    let decodedNegativeZeroCount: Int64
    let decodedNonFiniteCount: Int64
    let zeroRows: [Bool]
    let zeroColumns: [Bool]
    let rowSegmentZeroCounts: [Int: Int64]
    let columnBlockZeroCounts: [Int: Int]
    let allZeroBlockCounts: [String: Int64]
    let rowDuplicates: DuplicateStats
    let columnDuplicates: DuplicateStats
    let groupDuplicates: DuplicateStats
    let metadataRowDuplicates: DuplicateStats
    let decodedHash: String
    let scaleBiasEqualPositions: Int64
    let adjacentIdenticalScales: Int64
    let adjacentIdenticalBiases: Int64
    let adjacentIdenticalScaleBiasPairs: Int64
    let constantScaleRows: Int
    let constantBiasRows: Int
    let constantScaleBiasRows: Int
    let rank: RankCertificate

    var exactZeroRowCount: Int {
        zeroRows.reduce(0) { $0 + ($1 ? 1 : 0) }
    }

    var exactZeroColumnCount: Int {
        zeroColumns.reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}

struct TensorAudit: Sendable {
    let tensor: QuantizedTensor
    let matrices: [MatrixAudit]
    let weightSHA256: String
    let scalesSHA256: String
    let biasesSHA256: String?
    let codeHistogram: [UInt64]
    let scaleHistogram: [UInt16: UInt64]
    let biasHistogram: [UInt16: UInt64]
    let expertDuplicates: DuplicateStats?
    let gateUpPeerMetadataSHA256: String?
}

private struct HashLocation: Comparable {
    let hash: UInt64
    let index: Int

    static func < (lhs: HashLocation, rhs: HashLocation) -> Bool {
        if lhs.hash != rhs.hash { return lhs.hash < rhs.hash }
        return lhs.index < rhs.index
    }
}

private struct BlockTracker {
    let height: Int
    let width: Int
    var rowInBlock = 0
    var allZero: [Bool]
    var zeroCount: Int64 = 0

    init(height: Int, width: Int, columns: Int) {
        self.height = height
        self.width = width
        allZero = [Bool](repeating: true, count: columns / width)
    }

    mutating func observe(rowSegmentNonzero: [Bool]) {
        for index in allZero.indices where rowSegmentNonzero[index] {
            allZero[index] = false
        }
        rowInBlock += 1
        if rowInBlock == height {
            zeroCount += Int64(allZero.reduce(0) { $0 + ($1 ? 1 : 0) })
            allZero = [Bool](repeating: true, count: allZero.count)
            rowInBlock = 0
        }
    }
}

func auditQuantizedTensor(_ tensor: QuantizedTensor) throws -> TensorAudit {
    let matrixAudits: [MatrixAudit]
    if tensor.matrixCount == 1 {
        matrixAudits = [try auditMatrix(tensor, matrix: 0)]
    } else {
        let lock = NSLock()
        var results = [MatrixAudit?](repeating: nil, count: tensor.matrixCount)
        var firstError: Error?
        DispatchQueue.concurrentPerform(iterations: tensor.matrixCount) { matrix in
            do {
                let result = try auditMatrix(tensor, matrix: matrix)
                lock.lock()
                results[matrix] = result
                lock.unlock()
            } catch {
                lock.lock()
                if firstError == nil { firstError = error }
                lock.unlock()
            }
        }
        if let firstError { throw firstError }
        matrixAudits = try results.enumerated().map { index, result in
            guard let result else {
                throw AuditError.invalid(
                    "\(tensor.baseName): missing matrix audit \(index)"
                )
            }
            return result
        }
    }

    var codeHistogram = [UInt64](repeating: 0, count: 1 << tensor.policy.bits)
    var scaleHistogram: [UInt16: UInt64] = [:]
    var biasHistogram: [UInt16: UInt64] = [:]
    for matrix in matrixAudits {
        for code in codeHistogram.indices {
            codeHistogram[code] += matrix.codeHistogram[code]
        }
        mergeHistogram(matrix.scaleHistogram, into: &scaleHistogram)
        mergeHistogram(matrix.biasHistogram, into: &biasHistogram)
    }

    let expertDuplicates: DuplicateStats?
    if tensor.isExpertTensor {
        let locations = matrixAudits.map {
            HashLocation(hash: parseLeadingHash($0.decodedHash), index: $0.matrixIndex)
        }
        let zeroExperts = matrixAudits.filter {
            $0.decodedZeroCount == Int64(tensor.rows * tensor.columns)
        }.count
        expertDuplicates = classifyDuplicates(
            totalItems: tensor.matrixCount,
            zeroCount: zeroExperts,
            nonzeroLocations: locations.filter {
                matrixAudits[$0.index].decodedZeroCount
                    != Int64(tensor.rows * tensor.columns)
            },
            equal: { lhs, rhs in
                matricesEqual(tensor, lhs: lhs, rhs: rhs)
            },
            retainRepresentatives: false
        )
    } else {
        expertDuplicates = nil
    }

    return TensorAudit(
        tensor: tensor,
        matrices: matrixAudits,
        weightSHA256: tensor.weight.sha256(),
        scalesSHA256: tensor.scales.sha256(),
        biasesSHA256: tensor.biases?.sha256(),
        codeHistogram: codeHistogram,
        scaleHistogram: scaleHistogram,
        biasHistogram: biasHistogram,
        expertDuplicates: expertDuplicates,
        gateUpPeerMetadataSHA256: nil
    )
}

private func auditMatrix(_ tensor: QuantizedTensor, matrix: Int) throws -> MatrixAudit {
    let rows = tensor.rows
    let columns = tensor.columns
    let groups = tensor.groupsPerRow
    let groupSize = tensor.policy.groupSize
    let codeCount = 1 << tensor.policy.bits
    let segmentWidths = [8, 16, 32, 64].filter { columns % $0 == 0 }
    let blockShapes = [
        (8, 8),
        (16, 16),
        (32, 8),
        (32, 32),
        (32, 64),
        (64, 64),
    ].filter { rows % $0.0 == 0 && columns % $0.1 == 0 }

    var codeHistogram = [UInt64](repeating: 0, count: codeCount)
    var scaleHistogram: [UInt16: UInt64] = [:]
    var biasHistogram: [UInt16: UInt64] = [:]
    var zeroCount: Int64 = 0
    var positiveZeroCount: Int64 = 0
    var negativeZeroCount: Int64 = 0
    var nonFiniteCount: Int64 = 0
    var zeroRows = [Bool](repeating: false, count: rows)
    var columnNonzero = [Bool](repeating: false, count: columns)
    var columnHashes = [UInt64](repeating: hashOffset, count: columns)
    var rowLocations: [HashLocation] = []
    rowLocations.reserveCapacity(rows)
    var groupLocations: [HashLocation] = []
    groupLocations.reserveCapacity(rows * groups)
    var metadataLocations: [HashLocation] = []
    metadataLocations.reserveCapacity(rows)
    var zeroGroupCount = 0
    var rowSegmentZeroCounts: [Int: Int64] = [:]
    var trackers = blockShapes.map {
        BlockTracker(height: $0.0, width: $0.1, columns: columns)
    }
    var matrixHashA = hashOffset
    var matrixHashB = hashOffsetB

    var scaleBiasEqualPositions: Int64 = 0
    var adjacentIdenticalScales: Int64 = 0
    var adjacentIdenticalBiases: Int64 = 0
    var adjacentIdenticalPairs: Int64 = 0
    var constantScaleRows = 0
    var constantBiasRows = 0
    var constantPairRows = 0

    var segmentNonzeroByWidth: [Int: [Bool]] = [:]
    for width in segmentWidths {
        segmentNonzeroByWidth[width] = [Bool](
            repeating: false,
            count: columns / width
        )
        rowSegmentZeroCounts[width] = 0
    }

    for row in 0..<rows {
        for width in segmentWidths {
            segmentNonzeroByWidth[width] = [Bool](
                repeating: false,
                count: columns / width
            )
        }
        var rowHash = hashOffset
        var rowHasNonzero = false
        var metadataHash = hashOffsetB
        var firstScale: UInt16?
        var firstBias: UInt16?
        var previousScale: UInt16?
        var previousBias: UInt16?
        var rowScaleConstant = true
        var rowBiasConstant = true
        var rowPairConstant = true

        for group in 0..<groups {
            let scale = tensor.rawScale(matrix: matrix, row: row, group: group)
            let bias = tensor.rawBias(matrix: matrix, row: row, group: group)
            scaleHistogram[scale, default: 0] += 1
            if let bias {
                biasHistogram[bias, default: 0] += 1
                if scale == bias { scaleBiasEqualPositions += 1 }
            }
            if let previousScale {
                if previousScale == scale { adjacentIdenticalScales += 1 }
                if let bias, previousBias == bias { adjacentIdenticalBiases += 1 }
                if previousScale == scale, previousBias == bias {
                    adjacentIdenticalPairs += 1
                }
            }
            if let firstScale {
                if firstScale != scale { rowScaleConstant = false }
                if firstBias != bias { rowBiasConstant = false }
                if firstScale != scale || firstBias != bias { rowPairConstant = false }
            } else {
                firstScale = scale
                firstBias = bias
            }
            previousScale = scale
            previousBias = bias
            metadataHash = hashStep(metadataHash, UInt64(scale))
            metadataHash = hashStep(
                metadataHash,
                bias.map(UInt64.init) ?? 0x1_0000
            )

            var groupHash = hashOffset
            var groupHasNonzero = false
            let columnStart = group * groupSize
            for localColumn in 0..<groupSize {
                let column = columnStart + localColumn
                let code = tensor.rawCode(matrix: matrix, row: row, column: column)
                codeHistogram[Int(code)] += 1
                let bits = tensor.decodedBits(matrix: matrix, row: row, column: column)
                let magnitude = bits & 0x7fff
                let isZero = magnitude == 0
                if isZero {
                    zeroCount += 1
                    if bits & 0x8000 == 0 {
                        positiveZeroCount += 1
                    } else {
                        negativeZeroCount += 1
                    }
                } else {
                    rowHasNonzero = true
                    groupHasNonzero = true
                    columnNonzero[column] = true
                    for width in segmentWidths {
                        segmentNonzeroByWidth[width]![column / width] = true
                    }
                }
                if (bits & 0x7f80) == 0x7f80 {
                    nonFiniteCount += 1
                }
                groupHash = hashStep(groupHash, UInt64(bits))
                columnHashes[column] = hashStep(columnHashes[column], UInt64(bits))
            }
            rowHash = hashStep(rowHash, groupHash)
            if groupHasNonzero {
                groupLocations.append(
                    HashLocation(hash: groupHash, index: row * groups + group)
                )
            } else {
                zeroGroupCount += 1
            }
        }

        if rowScaleConstant { constantScaleRows += 1 }
        if rowBiasConstant { constantBiasRows += 1 }
        if rowPairConstant { constantPairRows += 1 }
        metadataLocations.append(HashLocation(hash: metadataHash, index: row))

        zeroRows[row] = !rowHasNonzero
        if rowHasNonzero {
            rowLocations.append(HashLocation(hash: rowHash, index: row))
        }
        matrixHashA = hashStep(matrixHashA, rowHash)
        matrixHashB = hashStepB(matrixHashB, rowHash)

        for width in segmentWidths {
            let segments = segmentNonzeroByWidth[width]!
            rowSegmentZeroCounts[width]! += Int64(
                segments.reduce(0) { $0 + ($1 ? 0 : 1) }
            )
        }
        for trackerIndex in trackers.indices {
            let width = trackers[trackerIndex].width
            trackers[trackerIndex].observe(
                rowSegmentNonzero: segmentNonzeroByWidth[width]!
            )
        }
    }

    let zeroColumns = columnNonzero.map { !$0 }
    let zeroRowCount = zeroRows.reduce(0) { $0 + ($1 ? 1 : 0) }
    let zeroColumnCount = zeroColumns.reduce(0) { $0 + ($1 ? 1 : 0) }

    let rowDuplicates = classifyDuplicates(
        totalItems: rows,
        zeroCount: zeroRowCount,
        nonzeroLocations: rowLocations,
        equal: { lhs, rhs in
            rowsEqual(tensor, matrix: matrix, lhs: lhs, rhs: rhs)
        },
        retainRepresentatives: true
    )
    let columnLocations = columnHashes.indices.compactMap { column -> HashLocation? in
        zeroColumns[column]
            ? nil
            : HashLocation(hash: columnHashes[column], index: column)
    }
    let columnDuplicates = classifyDuplicates(
        totalItems: columns,
        zeroCount: zeroColumnCount,
        nonzeroLocations: columnLocations,
        equal: { lhs, rhs in
            columnsEqual(tensor, matrix: matrix, lhs: lhs, rhs: rhs)
        },
        retainRepresentatives: true
    )
    let groupDuplicates = classifyDuplicates(
        totalItems: rows * groups,
        zeroCount: zeroGroupCount,
        nonzeroLocations: groupLocations,
        equal: { lhs, rhs in
            groupsEqual(tensor, matrix: matrix, lhs: lhs, rhs: rhs)
        },
        retainRepresentatives: false
    )
    let metadataDuplicates = classifyDuplicates(
        totalItems: rows,
        zeroCount: 0,
        nonzeroLocations: metadataLocations,
        equal: { lhs, rhs in
            metadataRowsEqual(tensor, matrix: matrix, lhs: lhs, rhs: rhs)
        },
        retainRepresentatives: false
    )

    var columnBlockZeroCounts: [Int: Int] = [:]
    for width in segmentWidths {
        var count = 0
        for start in stride(from: 0, to: columns, by: width) {
            if zeroColumns[start..<(start + width)].allSatisfy({ $0 }) {
                count += 1
            }
        }
        columnBlockZeroCounts[width] = count
    }
    var allZeroBlockCounts: [String: Int64] = [:]
    for tracker in trackers {
        allZeroBlockCounts["\(tracker.height)x\(tracker.width)"] = tracker.zeroCount
    }

    let rank: RankCertificate
    if nonFiniteCount == 0 {
        let rankRows = rowDuplicates.representativeMask!
        let rankColumns = columnDuplicates.representativeMask!
        rank = certifyExactRankLowerBound(
            tensor: tensor,
            matrix: matrix,
            nonzeroRows: rankRows,
            nonzeroColumns: rankColumns,
            uniqueNonzeroRowCount: rankRows.reduce(0) { $0 + ($1 ? 1 : 0) },
            uniqueNonzeroColumnCount: rankColumns.reduce(0) { $0 + ($1 ? 1 : 0) }
        )
    } else {
        let required = rankRequiredToRuleOut39Percent(rows: rows, columns: columns)
        rank = RankCertificate(
            status: "non-finite-decoded-values",
            prime: nil,
            exactLowerBound: 0,
            exactUpperBound: min(rowDuplicates.uniqueItems, columnDuplicates.uniqueItems),
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

    return MatrixAudit(
        matrixIndex: matrix,
        codeHistogram: codeHistogram,
        scaleHistogram: scaleHistogram,
        biasHistogram: biasHistogram,
        decodedZeroCount: zeroCount,
        decodedPositiveZeroCount: positiveZeroCount,
        decodedNegativeZeroCount: negativeZeroCount,
        decodedNonFiniteCount: nonFiniteCount,
        zeroRows: zeroRows,
        zeroColumns: zeroColumns,
        rowSegmentZeroCounts: rowSegmentZeroCounts,
        columnBlockZeroCounts: columnBlockZeroCounts,
        allZeroBlockCounts: allZeroBlockCounts,
        rowDuplicates: rowDuplicates,
        columnDuplicates: columnDuplicates,
        groupDuplicates: groupDuplicates,
        metadataRowDuplicates: metadataDuplicates,
        decodedHash: String(format: "%016llx%016llx", matrixHashA, matrixHashB),
        scaleBiasEqualPositions: scaleBiasEqualPositions,
        adjacentIdenticalScales: adjacentIdenticalScales,
        adjacentIdenticalBiases: adjacentIdenticalBiases,
        adjacentIdenticalScaleBiasPairs: adjacentIdenticalPairs,
        constantScaleRows: constantScaleRows,
        constantBiasRows: constantBiasRows,
        constantScaleBiasRows: constantPairRows,
        rank: rank
    )
}

private func classifyDuplicates(
    totalItems: Int,
    zeroCount: Int,
    nonzeroLocations: [HashLocation],
    equal: (Int, Int) -> Bool,
    retainRepresentatives: Bool
) -> DuplicateStats {
    var locations = nonzeroLocations
    locations.sort()
    var representativeMask = retainRepresentatives
        ? [Bool](repeating: false, count: totalItems)
        : nil
    var duplicateItems = 0
    var duplicateClasses = 0
    var maximumMultiplicity = zeroCount
    var unequalHashCollisions = 0
    var classSamples: [DuplicateClassSample] = []
    var classDigest = SHA256()

    if zeroCount > 0 {
        if zeroCount > 1 {
            duplicateItems += zeroCount - 1
            duplicateClasses += 1
            let sample = DuplicateClassSample(hash: "exact-zero", count: zeroCount)
            classSamples.append(sample)
            updateClassDigest(&classDigest, hash: 0, count: zeroCount)
        }
    }

    var cursor = 0
    while cursor < locations.count {
        var end = cursor + 1
        while end < locations.count, locations[end].hash == locations[cursor].hash {
            end += 1
        }
        var classes: [(representative: Int, count: Int)] = []
        for location in locations[cursor..<end] {
            if let classIndex = classes.firstIndex(where: {
                equal($0.representative, location.index)
            }) {
                classes[classIndex].count += 1
            } else {
                if !classes.isEmpty { unequalHashCollisions += 1 }
                classes.append((location.index, 1))
                representativeMask?[location.index] = true
            }
        }
        for exactClass in classes where exactClass.count > 1 {
            duplicateClasses += 1
            duplicateItems += exactClass.count - 1
            maximumMultiplicity = max(maximumMultiplicity, exactClass.count)
            updateClassDigest(
                &classDigest,
                hash: locations[cursor].hash,
                count: exactClass.count
            )
            if classSamples.count < 16 {
                classSamples.append(
                    DuplicateClassSample(
                        hash: String(format: "%016llx", locations[cursor].hash),
                        count: exactClass.count
                    )
                )
            }
        }
        cursor = end
    }

    return DuplicateStats(
        totalItems: totalItems,
        uniqueItems: totalItems - duplicateItems,
        duplicateItems: duplicateItems,
        duplicateClasses: duplicateClasses,
        maximumMultiplicity: max(maximumMultiplicity, totalItems > 0 ? 1 : 0),
        unequalHashCollisions: unequalHashCollisions,
        classDigestSHA256: classDigest.finalize().hexString,
        classSamples: classSamples,
        representativeMask: representativeMask
    )
}

private func rowsEqual(
    _ tensor: QuantizedTensor,
    matrix: Int,
    lhs: Int,
    rhs: Int
) -> Bool {
    for column in 0..<tensor.columns
    where tensor.decodedBits(matrix: matrix, row: lhs, column: column)
        != tensor.decodedBits(matrix: matrix, row: rhs, column: column)
    {
        return false
    }
    return true
}

private func columnsEqual(
    _ tensor: QuantizedTensor,
    matrix: Int,
    lhs: Int,
    rhs: Int
) -> Bool {
    for row in 0..<tensor.rows
    where tensor.decodedBits(matrix: matrix, row: row, column: lhs)
        != tensor.decodedBits(matrix: matrix, row: row, column: rhs)
    {
        return false
    }
    return true
}

private func groupsEqual(
    _ tensor: QuantizedTensor,
    matrix: Int,
    lhs: Int,
    rhs: Int
) -> Bool {
    let lhsRow = lhs / tensor.groupsPerRow
    let lhsGroup = lhs % tensor.groupsPerRow
    let rhsRow = rhs / tensor.groupsPerRow
    let rhsGroup = rhs % tensor.groupsPerRow
    for localColumn in 0..<tensor.policy.groupSize
    where tensor.decodedBits(
        matrix: matrix,
        row: lhsRow,
        column: lhsGroup * tensor.policy.groupSize + localColumn
    ) != tensor.decodedBits(
        matrix: matrix,
        row: rhsRow,
        column: rhsGroup * tensor.policy.groupSize + localColumn
    )
    {
        return false
    }
    return true
}

private func metadataRowsEqual(
    _ tensor: QuantizedTensor,
    matrix: Int,
    lhs: Int,
    rhs: Int
) -> Bool {
    for group in 0..<tensor.groupsPerRow {
        if tensor.rawScale(matrix: matrix, row: lhs, group: group)
            != tensor.rawScale(matrix: matrix, row: rhs, group: group)
        {
            return false
        }
        if tensor.rawBias(matrix: matrix, row: lhs, group: group)
            != tensor.rawBias(matrix: matrix, row: rhs, group: group)
        {
            return false
        }
    }
    return true
}

private func matricesEqual(_ tensor: QuantizedTensor, lhs: Int, rhs: Int) -> Bool {
    for row in 0..<tensor.rows {
        for column in 0..<tensor.columns
        where tensor.decodedBits(matrix: lhs, row: row, column: column)
            != tensor.decodedBits(matrix: rhs, row: row, column: column)
        {
            return false
        }
    }
    return true
}

private func mergeHistogram(
    _ source: [UInt16: UInt64],
    into destination: inout [UInt16: UInt64]
) {
    for (value, count) in source {
        destination[value, default: 0] += count
    }
}

@inline(__always)
private func parseLeadingHash(_ hash: String) -> UInt64 {
    UInt64(hash.prefix(16), radix: 16)!
}

private let hashOffset: UInt64 = 0xcbf2_9ce4_8422_2325
private let hashOffsetB: UInt64 = 0x6a09_e667_f3bc_c909

@inline(__always)
private func hashStep(_ hash: UInt64, _ value: UInt64) -> UInt64 {
    var next = hash ^ value
    next &*= 0x0000_0100_0000_01b3
    next ^= next >> 32
    return next
}

@inline(__always)
private func hashStepB(_ hash: UInt64, _ value: UInt64) -> UInt64 {
    var next = hash &+ value &+ 0x9e37_79b9_7f4a_7c15
    next = (next ^ (next >> 30)) &* 0xbf58_476d_1ce4_e5b9
    return next ^ (next >> 27)
}

private func updateClassDigest(
    _ digest: inout SHA256,
    hash: UInt64,
    count: Int
) {
    var littleHash = hash.littleEndian
    var littleCount = UInt64(count).littleEndian
    withUnsafeBytes(of: &littleHash) { digest.update(bufferPointer: $0) }
    withUnsafeBytes(of: &littleCount) { digest.update(bufferPointer: $0) }
}
