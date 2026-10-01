import Foundation

public enum RiskLevel: Int, Sendable, Comparable, CaseIterable {
    case safe, low, medium, high, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    init?(name: String) {
        switch name.lowercased() {
        case "safe": self = .safe
        case "low": self = .low
        case "medium": self = .medium
        case "high": self = .high
        case "critical": self = .critical
        default: return nil
        }
    }

    var name: String {
        switch self {
        case .safe: "safe"
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .critical: "critical"
        }
    }
}

public struct RuleRisk: Sendable, Hashable {
    public let level: RiskLevel
    public let reason: String

    init(level: RiskLevel, reason: String) {
        self.level = level
        self.reason = reason
    }

    static func of(_ category: SweepCategory) -> RuleRisk {
        switch category {
        case .cleanable(.devCaches): RuleRisk(level: .safe, reason: "删除后工具会重新生成")
        case .cleanable(.userLogs): RuleRisk(level: .safe, reason: "日志可以重新生成")
        case .cleanable(.userCaches): RuleRisk(level: .low, reason: "应用缓存。个别应用会把状态放在这里")
        case .cleanable(.browserCaches): RuleRisk(level: .low, reason: "浏览器缓存。默认不勾选")
        case .cleanable(.oldInstallers): RuleRisk(level: .medium, reason: "安装包删除后需要重新下载")
        case .report(.trash): RuleRisk(level: .high, reason: "这里是占用体积。清空会永久删除，所以不能清理")
        case .report(.largeFiles): RuleRisk(level: .medium, reason: "大文件可能是你的资料，只报告不清理")
        }
    }
}

public struct AssessedRisk: Sendable, Hashable {
    public let rule: RuleRisk
    public let raisedTo: RiskLevel?
    public let modelExplanation: String?

    public var level: RiskLevel { max(rule.level, raisedTo ?? rule.level) }

    init(rule: RuleRisk) {
        self.rule = rule
        self.raisedTo = nil
        self.modelExplanation = nil
    }

    init(rule: RuleRisk, note: ModelNote) {
        self.rule = rule
        self.raisedTo = note.proposed.flatMap { $0 > rule.level ? $0 : nil }
        self.modelExplanation = note.explanation.isEmpty ? nil : note.explanation
    }
}

public enum AssessmentSource: Sendable, Equatable {
    case rulesOnly(RulesOnlyReason)
    case modelReviewed(model: String)
}

public enum RulesOnlyReason: Sendable, Equatable {
    case noAPIKey, reviewPending, reviewFailed(String)
}

public protocol Reviewer: Sendable {
    var modelName: String { get }
    func review(_ items: [ReviewItem]) async throws -> [String: ModelNote]
}

public struct ReviewItem: Sendable {
    public let findingID: String
    public let category: SweepCategory
    public let displayPath: String
    public let bytes: Int64
    public let rule: RuleRisk

    init(_ finding: Finding) {
        findingID = finding.id
        category = finding.category
        displayPath = finding.displayPath
        bytes = finding.bytes
        rule = finding.risk.rule
    }
}

public struct ModelNote: Sendable {
    public let proposed: RiskLevel?
    public let explanation: String

    public init(proposed: RiskLevel?, explanation: String) {
        self.proposed = proposed
        self.explanation = explanation
    }
}
