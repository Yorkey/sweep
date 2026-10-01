import Foundation

public enum SweepCategory: Sendable, Hashable, CaseIterable {
    case cleanable(CleanableCategory)
    case report(ReportCategory)

    public static var allCases: [SweepCategory] {
        CleanableCategory.allCases.map(SweepCategory.cleanable) + ReportCategory.allCases.map(SweepCategory.report)
    }
}

public enum CleanableCategory: String, Sendable, Hashable, CaseIterable {
    case userCaches, userLogs, oldInstallers, devCaches, browserCaches
}

public enum ReportCategory: String, Sendable, Hashable, CaseIterable {
    case trash, largeFiles
}

public struct SkippedLocation: Sendable {
    public let path: String
    public let reason: String
}

public struct CleanableID: Sendable, Hashable {
    let raw: String
}

public struct ReportID: Sendable, Hashable {
    let raw: String
}

public struct Cleanable: Sendable, Identifiable {
    public let id: CleanableID
    public let category: CleanableCategory
    public let displayName: String
    public let displayPath: String
    public let bytes: Int64
    public let risk: AssessedRisk
    let target: CleanTarget

    func with(risk: AssessedRisk) -> Cleanable {
        Cleanable(id: id, category: category, displayName: displayName, displayPath: displayPath,
                  bytes: bytes, risk: risk, target: target)
    }
}

public struct Report: Sendable, Identifiable {
    public let id: ReportID
    public let category: ReportCategory
    public let displayName: String
    public let displayPath: String
    public let bytes: Int64
    public let risk: AssessedRisk
    public let revealURL: URL

    func with(risk: AssessedRisk) -> Report {
        Report(id: id, category: category, displayName: displayName, displayPath: displayPath,
               bytes: bytes, risk: risk, revealURL: revealURL)
    }
}

public enum Finding: Sendable, Identifiable {
    case cleanable(Cleanable)
    case report(Report)

    public var id: String {
        switch self {
        case .cleanable(let c): c.id.raw
        case .report(let r): r.id.raw
        }
    }

    public var bytes: Int64 {
        switch self {
        case .cleanable(let c): c.bytes
        case .report(let r): r.bytes
        }
    }

    public var risk: AssessedRisk {
        switch self {
        case .cleanable(let c): c.risk
        case .report(let r): r.risk
        }
    }

    public var displayName: String {
        switch self {
        case .cleanable(let c): c.displayName
        case .report(let r): r.displayName
        }
    }

    var category: SweepCategory {
        switch self {
        case .cleanable(let c): .cleanable(c.category)
        case .report(let r): .report(r.category)
        }
    }

    var displayPath: String {
        switch self {
        case .cleanable(let c): c.displayPath
        case .report(let r): r.displayPath
        }
    }

    func with(risk: AssessedRisk) -> Finding {
        switch self {
        case .cleanable(let c): .cleanable(c.with(risk: risk))
        case .report(let r): .report(r.with(risk: risk))
        }
    }
}

public struct CategoryGroup: Sendable, Identifiable {
    public let category: SweepCategory
    public let findings: [Finding]
    public var id: SweepCategory { category }
    public var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
}

public struct SweepPlan: Sendable {
    public let groups: [CategoryGroup]
    public let assessment: AssessmentSource
    public let skipped: [SkippedLocation]

    public var allFindings: [Finding] { groups.flatMap(\.findings) }

    var cleanables: [Cleanable] {
        allFindings.compactMap { finding in
            if case .cleanable(let c) = finding { c } else { nil }
        }
    }

    public func order(for selection: Selection) -> CleanOrder {
        CleanOrder(cleanables: cleanables.filter(selection.contains))
    }

    public func selectedBytes(_ selection: Selection) -> Int64 {
        order(for: selection).cleanables.reduce(0) { $0 + $1.bytes }
    }

    func assessed(by notes: [String: ModelNote], model: String) -> SweepPlan {
        let reviewed = groups.map { group in
            CategoryGroup(category: group.category, findings: group.findings.map { finding in
                guard let note = notes[finding.id] else { return finding }
                return finding.with(risk: AssessedRisk(rule: finding.risk.rule, note: note))
            })
        }
        return SweepPlan(groups: reviewed, assessment: .modelReviewed(model: model), skipped: skipped)
    }

    func with(assessment: AssessmentSource) -> SweepPlan {
        SweepPlan(groups: groups, assessment: assessment, skipped: skipped)
    }
}

public struct Selection: Sendable, Equatable {
    private var overrides: [CleanableID: Bool] = [:]

    public init() {}

    public func contains(_ finding: Cleanable) -> Bool {
        overrides[finding.id] ?? (finding.risk.level <= .low && finding.category != .browserCaches)
    }

    public mutating func set(_ id: CleanableID, selected: Bool) {
        overrides[id] = selected
    }

    public mutating func resetToDefault() {
        overrides.removeAll()
    }
}

public struct CleanOrder: Sendable {
    let cleanables: [Cleanable]
    public var count: Int { cleanables.count }
    public var allLevels: [RiskLevel] { cleanables.map(\.risk.level) }
}

public struct CleanReport: Sendable {
    public let outcomes: [CleanableID: CleanOutcome]
    let bytes: [CleanableID: Int64]

    public var converged: Bool { outcomes.values.allSatisfy(\.isConvergedSuccess) }

    public var movedBytes: Int64 {
        outcomes.reduce(0) { sum, entry in
            if case .moved = entry.value { sum + (bytes[entry.key] ?? 0) } else { sum }
        }
    }
}

public enum CleanOutcome: Sendable, Equatable {
    case moved(to: URL)
    case alreadyGone
    case changedSinceScan
    case refusedProtected
    case failed(String)

    public var isConvergedSuccess: Bool {
        switch self {
        case .moved, .alreadyGone: true
        case .changedSinceScan, .refusedProtected, .failed: false
        }
    }
}
