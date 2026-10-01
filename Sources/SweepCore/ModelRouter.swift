import Foundation

public struct ModelRouter: Reviewer {
    public let chat: ModelReviewer?
    public let jev: JevJudge?

    public init(chat: ModelReviewer?, jev: JevJudge?) {
        self.chat = chat
        self.jev = jev
    }

    public var modelName: String { jev?.modelName ?? chat?.modelName ?? "" }
    public var canJudge: Bool { jev != nil || chat != nil }
    public var canExplain: Bool { chat != nil }

    public func review(_ items: [ReviewItem]) async throws -> [String: ModelNote] {
        try await preferJev({ try await jev?.review(items) }, or: { try await chat?.review(items) })
    }

    public func judge(_ survey: ResidueSurvey) async throws -> [String: LeftoverVerdict] {
        try await preferJev({ try await jev?.judge(survey) }, or: { try await chat?.judge(survey) })
    }

    public func explain(_ finding: Finding) async throws -> PathBrief {
        guard let chat else { throw ModelRouteError.noWritingModel }
        return try await chat.explain(finding)
    }

    public func explain(_ candidate: LeftoverCandidate) async throws -> PathBrief {
        guard let chat else { throw ModelRouteError.noWritingModel }
        return try await chat.explain(candidate)
    }

    private func preferJev<T>(_ jevCall: () async throws -> T?, or chatCall: () async throws -> T?) async throws -> T {
        if jev != nil {
            do {
                if let value = try await jevCall() { return value }
            } catch {
                if let value = try await chatCall() { return value }
                throw error
            }
        }
        if let value = try await chatCall() { return value }
        throw ModelRouteError.noJudge
    }
}

public enum ModelRouteError: Error, CustomStringConvertible {
    case noWritingModel
    case noJudge

    public var description: String {
        switch self {
        case .noWritingModel: "询问说明需要生成模型。Jev 只做判断。"
        case .noJudge: "没有可用的判断模型。"
        }
    }
}
