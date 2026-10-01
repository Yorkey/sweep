import Foundation
@testable import SweepCore

final class Fixture {
    let root: URL
    let home: URL
    let trash: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SweepTests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 10, modified: Date? = nil) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    func symlink(_ relative: String, to destination: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: home.appendingPathComponent(destination))
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    func environment(threshold: Int64 = 1 << 30, reviewer: (any Reviewer)? = nil) -> SweepEnvironment {
        SweepEnvironment(home: home, now: now, largeFileThreshold: threshold,
                         trash: .directory(trash), reviewer: reviewer)
    }
}

func collect(_ stream: AsyncThrowingStream<SweepPlan, any Error>) async throws -> [SweepPlan] {
    var plans: [SweepPlan] = []
    for try await plan in stream {
        plans.append(plan)
    }
    return plans
}

func finalPlan(_ environment: SweepEnvironment) async throws -> SweepPlan {
    let plans = try await collect(Sweep(environment: environment).scan())
    guard let last = plans.last else { throw NoPlan() }
    return last
}

struct NoPlan: Error {}

extension SweepPlan {
    func finding(at displayPath: String) -> Finding? {
        allFindings.first { finding in
            switch finding {
            case .cleanable(let c): c.displayPath == displayPath
            case .report(let r): r.displayPath == displayPath
            }
        }
    }

    var displayPaths: [String] {
        allFindings.map { finding in
            switch finding {
            case .cleanable(let c): c.displayPath
            case .report(let r): r.displayPath
            }
        }
    }
}

struct StubReviewer: Reviewer {
    let modelName = "stub"
    let propose: @Sendable (ReviewItem) -> RiskLevel?

    func review(_ items: [ReviewItem]) async throws -> [String: ModelNote] {
        Dictionary(uniqueKeysWithValues: items.map { item in
            (item.findingID, ModelNote(proposed: propose(item), explanation: "复核：\(item.displayPath)"))
        })
    }
}

struct FailingReviewer: Reviewer {
    let modelName = "broken"
    struct Down: Error {}
    func review(_ items: [ReviewItem]) async throws -> [String: ModelNote] { throw Down() }
}
