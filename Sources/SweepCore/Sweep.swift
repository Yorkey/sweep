import Foundation

public enum TrashDestination: Sendable {
    case system
    case directory(URL)
}

public struct SweepEnvironment: Sendable {
    public var home: URL
    public var now: Date
    public var largeFileThreshold: Int64
    public var trash: TrashDestination
    public var reviewer: (any Reviewer)?

    public init(home: URL, now: Date = .now, largeFileThreshold: Int64 = 1 << 30,
                trash: TrashDestination = .system, reviewer: (any Reviewer)? = nil) {
        self.home = home
        self.now = now
        self.largeFileThreshold = largeFileThreshold
        self.trash = trash
        self.reviewer = reviewer
    }

    public static func live() -> SweepEnvironment {
        SweepEnvironment(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

public actor Sweep {
    private let environment: SweepEnvironment

    public init(environment: SweepEnvironment) {
        self.environment = environment
    }

    public func scan() -> AsyncThrowingStream<SweepPlan, any Error> {
        let environment = environment
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try await Self.scan(environment, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CancellationError())
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func clean(_ order: CleanOrder) async -> CleanReport {
        let zones = Locator(environment: environment).zones
        var outcomes: [CleanableID: CleanOutcome] = [:]
        var bytes: [CleanableID: Int64] = [:]
        for cleanable in order.cleanables {
            outcomes[cleanable.id] = Admission.recheck(cleanable.target, zones: zones)
                ?? Admission.move(cleanable.target, to: environment.trash)
            bytes[cleanable.id] = cleanable.bytes
        }
        return CleanReport(outcomes: outcomes, bytes: bytes)
    }

    /// Throws only on cancellation.
    private static func scan(_ environment: SweepEnvironment,
                             into continuation: AsyncThrowingStream<SweepPlan, any Error>.Continuation) async throws {
        let locator = Locator(environment: environment)
        let pending: AssessmentSource = environment.reviewer == nil ? .rulesOnly(.noAPIKey) : .rulesOnly(.reviewPending)
        var groups: [CategoryGroup] = []
        var skipped: [SkippedLocation] = []
        for category in SweepCategory.allCases {
            try Task.checkCancellation()
            let findings = try locator.findings(for: category, skipped: &skipped)
            if !findings.isEmpty {
                groups.append(CategoryGroup(category: category, findings: findings))
            }
            continuation.yield(SweepPlan(groups: groups, assessment: pending, skipped: skipped))
        }

        guard let reviewer = environment.reviewer else { return }
        let plan = SweepPlan(groups: groups, assessment: pending, skipped: skipped)
        do {
            let notes = try await reviewer.review(plan.allFindings.map(ReviewItem.init))
            try Task.checkCancellation()
            continuation.yield(plan.assessed(by: notes, model: reviewer.modelName))
        } catch {
            try Task.checkCancellation()
            continuation.yield(plan.with(assessment: .rulesOnly(.reviewFailed(String(describing: error)))))
        }
    }
}
