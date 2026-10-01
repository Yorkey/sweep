import Foundation

public struct JevJudge: Sendable {
    public let modelName: String
    private let apiKey: String
    private let baseURL: URL

    public static let minimumConfidence = 0.5

    public init?(apiKey: String?, baseURL: URL, model: String) {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else { return nil }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        self.apiKey = apiKey
        self.baseURL = baseURL
        modelName = model
    }

    public func review(_ items: [ReviewItem]) async throws -> [String: ModelNote] {
        guard !items.isEmpty else { return [:] }
        var notes: [String: ModelNote] = [:]
        for chunk in items.chunked(by: 40) {
            let indexed = Array(chunk.enumerated())
            let state: [String: Any] = [
                "items": indexed.map { offset, item in
                    [
                        "key": "q\(offset)",
                        "path": item.displayPath,
                        "bytes": item.bytes,
                        "ruleLevel": item.rule.level.name,
                        "ruleReason": item.rule.reason,
                    ]
                },
            ]
            var questions: [String: Any] = [:]
            for (offset, _) in indexed {
                questions["q\(offset)"] = [
                    "type": "choice",
                    "instructions": "Look at item q\(offset) in state. Choose the risk of deleting that path. Stay at the rule level unless the path likely holds user data, login state, or something that would not be recreated.",
                    "criteria": Self.riskCriteria,
                ]
            }
            let answers = try await ask(state: state, questions: questions)
            for (offset, item) in indexed {
                guard let answer = answers["q\(offset)"], answer.confident else { continue }
                guard let level = answer.choice.flatMap(RiskLevel.init(name:)) else { continue }
                notes[item.findingID] = ModelNote(proposed: level, explanation: "")
            }
        }
        return notes
    }

    public func judge(_ survey: ResidueSurvey) async throws -> [String: LeftoverVerdict] {
        let batch = Array(survey.candidates.prefix(Residue.judgeLimit))
        guard !batch.isEmpty else { return [:] }
        let indexed = Array(batch.enumerated())
        let state: [String: Any] = [
            "installed": survey.installed.map { ["name": $0.name, "bundleIdentifier": $0.bundleIdentifier] },
            "candidates": indexed.map { offset, candidate in
                [
                    "key": "q\(offset)",
                    "path": candidate.displayPath,
                    "bytes": candidate.bytes,
                    "place": candidate.place.label,
                ]
            },
        ]
        var questions: [String: Any] = [:]
        for (offset, _) in indexed {
            questions["q\(offset)"] = [
                "type": "choice",
                "instructions": "Using the installed app list in state, classify candidate q\(offset). leftover only when the owning app is gone and macOS does not share that folder.",
                "criteria": Self.leftoverCriteria,
            ]
        }
        let answers = try await ask(state: state, questions: questions)
        var verdicts: [String: LeftoverVerdict] = [:]
        for (offset, candidate) in indexed {
            guard let answer = answers["q\(offset)"] else { continue }
            verdicts[candidate.id] = Self.verdict(from: answer)
        }
        return verdicts
    }

    static func verdict(from answer: JevAnswer) -> LeftoverVerdict {
        let kind = LeftoverVerdictKind(rawValue: answer.choice ?? "") ?? .unsure
        if kind == .leftover, !answer.confident {
            return LeftoverVerdict(kind: .unsure, note: "倾向残留，但置信度不够。")
        }
        switch kind {
        case .leftover: return LeftoverVerdict(kind: .leftover, note: "判断为已卸载应用留下的。")
        case .keep: return LeftoverVerdict(kind: .keep, note: "判断为仍在使用。")
        case .unsure: return LeftoverVerdict(kind: .unsure, note: "判断不确定。")
        }
    }

    static func decodeAnswers(_ data: Data) throws -> [String: JevAnswer] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReviewFailure.emptyReply
        }
        let raw = object["answers"] as? [String: Any]
            ?? (object["data"] as? [String: Any])?["answers"] as? [String: Any]
        guard let raw, !raw.isEmpty else { throw ReviewFailure.emptyReply }
        var answers: [String: JevAnswer] = [:]
        for (key, value) in raw {
            guard let dict = value as? [String: Any] else { continue }
            let nested = dict["choice"] as? [String: Any]
            let choice = dict["choice"] as? String ?? nested?["choice"] as? String ?? dict["selected"] as? String
            let confidence = Self.number(dict["confidence"]) ?? nested.flatMap { Self.number($0["confidence"]) }
            answers[key] = JevAnswer(choice: choice, confidence: confidence)
        }
        if answers.isEmpty { throw ReviewFailure.emptyReply }
        return answers
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private func ask(state: Any, questions: [String: Any]) async throws -> [String: JevAnswer] {
        let body: [String: Any] = ["model": modelName, "state": state, "questions": questions]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReviewFailure.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw ReviewFailure.status(http.statusCode) }
        return try Self.decodeAnswers(data)
    }

    private var endpoint: URL {
        baseURL.lastPathComponent == "systemone" ? baseURL : baseURL.appending(path: "systemone")
    }

    private static let riskCriteria: [String: String] = [
        "safe": "Deleting only drops a cache or log that is recreated automatically, with no personal data.",
        "low": "Mostly a cache. A few apps may keep a little state here.",
        "medium": "Deleting means a re-download or mild inconvenience, not unique personal data.",
        "high": "May hold login state, settings, or data that is annoying to lose.",
        "critical": "Looks like irreplaceable personal data or system state.",
    ]

    private static let leftoverCriteria: [String: String] = [
        "leftover": "The app that owned this folder is not installed, and macOS does not share the folder.",
        "keep": "An installed app or macOS still uses this folder.",
        "unsure": "The path could belong to either, or there is not enough to tell.",
    ]
}

public struct JevAnswer: Sendable {
    public let choice: String?
    public let confidence: Double?

    public init(choice: String?, confidence: Double?) {
        self.choice = choice
        self.confidence = confidence
    }

    var confident: Bool {
        guard let confidence else { return true }
        return confidence >= JevJudge.minimumConfidence
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
