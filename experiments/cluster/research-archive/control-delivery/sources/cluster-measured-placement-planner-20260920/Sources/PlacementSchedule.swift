import Foundation

struct PlacementScheduledTask: Codable, Sendable {
    let id: String
    let measurementID: String
    let evidenceSHA256: String
    let startNanoseconds: UInt64
    let endNanoseconds: UInt64
    let resources: [PlacementResource]
    let costComponents: [String: UInt64]
}

struct PlacementSchedule: Codable, Sendable {
    let nanoseconds: UInt64
    let tasks: [PlacementScheduledTask]
}

enum PlacementScheduling {
    // Deterministic earliest-feasible list scheduling. It models this explicit
    // resource policy, not an optimal arbitrary-DAG schedule or a runtime peak.
    // One serialized link and both endpoint hosts are charged during transfer.
    static func schedule(_ tasks: [PlacementTask], phase: PlacementPhase,
                         costs: PlacementCostLookup) throws -> PlacementSchedule {
        // Autoregressive tokens cannot overlap even when an adapter accidentally
        // omits a cross-token edge. Handoff is separately sequenced by planner.
        if phase == .decode {
            var offset: UInt64 = 0
            var all = [PlacementScheduledTask]()
            for step in Set(tasks.map(\.step)).sorted() {
                let selected = tasks.filter { $0.step == step }
                let ids = Set(selected.map(\.id))
                let local = selected.map { PlacementTask(id: $0.id, step: $0.step,
                    dependencies: $0.dependencies.filter { ids.contains($0) }, work: $0.work) }
                let window = try scheduleWindow(local, phase: phase, costs: costs)
                for task in window.tasks {
                    all.append(.init(id: task.id, measurementID: task.measurementID,
                        evidenceSHA256: task.evidenceSHA256,
                        startNanoseconds: try PlacementMath.sum([offset, task.startNanoseconds]),
                        endNanoseconds: try PlacementMath.sum([offset, task.endNanoseconds]),
                        resources: task.resources, costComponents: task.costComponents))
                }
                offset = try PlacementMath.sum([offset, window.nanoseconds])
            }
            return .init(nanoseconds: offset, tasks: all)
        }
        if phase == .prefill {
            // Preserve each local operator's chunk order (including cache
            // updates). Adapter edges separately express transport ACK credit
            // and its admitted prepared-buffer frontier.
            var prior: [String: String] = [:]
            var augmented = tasks
            for index in tasks.indices.sorted(by: {
                tasks[$0].step == tasks[$1].step ? $0 < $1 : tasks[$0].step < tasks[$1].step
            }) {
                let task = tasks[index]
                if case .local(let rank, let operators, _) = task.work {
                    var dependencies = Set(task.dependencies)
                    for op in operators {
                        let key = "\(rank)|" + op
                        if let previous = prior[key] { dependencies.insert(previous) }
                        prior[key] = task.id
                    }
                    guard dependencies.count <= 64 else { throw PlacementError.invalid("local causal frontier") }
                    augmented[index] = .init(id: task.id, step: task.step,
                        dependencies: dependencies.sorted(), work: task.work)
                }
            }
            return try scheduleWindow(augmented, phase: phase, costs: costs)
        }
        return try scheduleWindow(tasks, phase: phase, costs: costs)
    }

    private static func scheduleWindow(_ tasks: [PlacementTask], phase: PlacementPhase,
                                        costs: PlacementCostLookup) throws -> PlacementSchedule {
        if tasks.isEmpty { return .init(nanoseconds: 0, tasks: []) }
        let indices = Dictionary(uniqueKeysWithValues: tasks.enumerated().map { ($0.element.id, $0.offset) })
        var waiting = tasks.map { $0.dependencies.count }
        var successors = Array(repeating: [Int](), count: tasks.count)
        var release = Array(repeating: UInt64(0), count: tasks.count)
        var ready = [Int]()
        var measured = [PlacementTaskCost]()
        for (index, task) in tasks.enumerated() {
            measured.append(try costs.cost(task, phase: phase))
            for parent in task.dependencies { successors[indices[parent]!].append(index) }
            if waiting[index] == 0 { ready.append(index) }
        }
        var resourceFree: [PlacementResource: UInt64] = [:]
        var result = [PlacementScheduledTask]()
        var makespan: UInt64 = 0
        while !ready.isEmpty {
            guard ready.count <= 64 else { throw PlacementError.scheduleWidth }
            var chosenPosition = 0, earliest = UInt64.max
            for (position, index) in ready.enumerated() {
                let start = max(release[index], measured[index].resources.map { resourceFree[$0, default: 0] }.max() ?? 0)
                if start < earliest || (start == earliest && index < ready[chosenPosition]) {
                    chosenPosition = position; earliest = start
                }
            }
            let index = ready.remove(at: chosenPosition)
            let measurement = measured[index]
            let end = try PlacementMath.sum([earliest, measurement.nanoseconds])
            for resource in measurement.resources { resourceFree[resource] = end }
            makespan = max(makespan, end)
            result.append(.init(id: tasks[index].id, measurementID: measurement.measurementID,
                                evidenceSHA256: measurement.evidenceSHA256, startNanoseconds: earliest,
                                endNanoseconds: end, resources: measurement.resources.sorted { $0.rawValue < $1.rawValue },
                                costComponents: measurement.components))
            for next in successors[index] {
                release[next] = max(release[next], end)
                waiting[next] -= 1
                if waiting[next] == 0 { ready.append(next) }
            }
        }
        guard result.count == tasks.count else { throw PlacementError.cyclicGraph }
        return .init(nanoseconds: makespan, tasks: result)
    }
}
