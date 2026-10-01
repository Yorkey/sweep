import Foundation

public struct ModelReviewer: Reviewer {
    private let apiKey: String
    private let baseURL: URL
    private let model: String

    public init?(apiKey: String?, baseURL: URL, model: String) {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else { return nil }
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    public var modelName: String { model }

    public func review(_ items: [ReviewItem]) async throws -> [String: ModelNote] {
        let content = try await complete(instructions: Self.reviewInstructions, payload: Self.reviewPayload(items))
        return try Self.parse(Data(content.utf8))
    }

    public func explain(_ finding: Finding) async throws -> PathBrief {
        let item = ReviewItem(finding)
        return try await explain(path: item.displayPath, bytes: item.bytes, context: Self.name(of: item.category))
    }

    public func explain(_ candidate: LeftoverCandidate) async throws -> PathBrief {
        try await explain(
            path: candidate.displayPath,
            bytes: candidate.bytes,
            context: "残留候选，位于\(candidate.place.label)。本机已安装应用对不上这个名字。"
        )
    }

    private func explain(path: String, bytes: Int64, context: String) async throws -> PathBrief {
        let payload: [String: Any] = ["path": path, "bytes": bytes, "context": context]
        let content = try await complete(instructions: Self.explainInstructions, payload: payload)
        return try Self.parseBrief(Data(content.utf8))
    }

    public func judge(_ survey: ResidueSurvey) async throws -> [String: LeftoverVerdict] {
        let batch = Array(survey.candidates.prefix(Residue.judgeLimit))
        let indexed = Array(batch.enumerated())
        let payload: [String: Any] = [
            "installed": survey.installed.map {
                ["name": $0.name, "bundleIdentifier": $0.bundleIdentifier]
            },
            "candidates": indexed.map { offset, candidate in
                [
                    "id": "q\(offset)",
                    "path": candidate.displayPath,
                    "bytes": candidate.bytes,
                    "place": candidate.place.label,
                ]
            },
        ]
        let content = try await complete(instructions: Self.judgeInstructions, payload: payload)
        return Self.attach(try Self.parseVerdicts(Data(content.utf8)), to: indexed)
    }

    static func attach(
        _ parsed: [String: LeftoverVerdict],
        to indexed: [(offset: Int, element: LeftoverCandidate)]
    ) -> [String: LeftoverVerdict] {
        var mapped: [String: LeftoverVerdict] = [:]
        for (offset, candidate) in indexed {
            let verdict = parsed["q\(offset)"] ?? parsed[candidate.id] ?? parsed[candidate.displayPath]
            if let verdict { mapped[candidate.id] = verdict }
        }
        return mapped
    }

    private func complete(instructions: String, payload: Any) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.chatBody(instructions: instructions, payload: payload, model: model)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReviewFailure.notHTTP }
        guard (200..<300).contains(http.statusCode) else { throw ReviewFailure.status(http.statusCode) }
        return try Self.messageContent(data)
    }

    private static let reviewInstructions = """
    You review a macOS disk cleaner's findings. Each item has a rule risk level. \
    Reply with one JSON object mapping each item id to {"level": "safe|low|medium|high|critical", "explanation": "..."}. \
    Raise the level when a path may hold user data or app state. Write the explanation in Simplified Chinese, one sentence.
    """

    private static let explainInstructions = """
    你在帮一个人看 Mac 上的一个路径，好决定要不要清掉。你只有路径、体积和它所在的分类，看不到文件内容。

    用简体中文写给这个人看，放进 JSON：{"text":"..."}。
    像当面讲。不要加小标题，也不要排成「它是做什么的」「谁依赖它」「删除后果」这种固定三段。
    这几件事只是可以提到的例子，用得上再写。它大概是什么，谁会用到，删了会少什么，系统或应用会不会自己再造一份。
    只写和这个路径有关的话。拿不准就说拿不准。两到三段，段与段之间空一行。
    """

    private static let judgeInstructions = """
    你在对照已安装的 Mac 应用，和一些可能是卸载后留下的目录。
    回复一个 JSON 对象。键必须原样使用候选里的 id（q0、q1 这种），值是 {"verdict":"leftover|keep|unsure","note":"..."}。
    leftover 表示原来的应用已经不在，而且系统不会共用这个目录。
    keep 表示还有已安装的应用或系统在用。
    note 用一句口语说明你为什么这么看，不要拆成小标题。
    """

    private static func reviewPayload(_ items: [ReviewItem]) -> [[String: Any]] {
        items.map { item in
            [
                "id": item.findingID,
                "category": name(of: item.category),
                "path": item.displayPath,
                "bytes": item.bytes,
                "ruleLevel": item.rule.level.name,
                "ruleReason": item.rule.reason,
            ]
        }
    }

    static func chatBody(instructions: String, payload: Any, model: String) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func messageContent(_ data: Data) throws -> String {
        let completion = try JSONDecoder().decode(Completion.self, from: data)
        guard let content = completion.choices.first?.message.content, !content.isEmpty else {
            throw ReviewFailure.emptyReply
        }
        return content
    }

    static func parse(_ data: Data) throws -> [String: ModelNote] {
        let entries = try JSONDecoder().decode([String: Entry].self, from: data)
        return entries.mapValues { entry in
            ModelNote(proposed: entry.level.flatMap(RiskLevel.init(name:)), explanation: entry.explanation ?? "")
        }
    }

    static func parseBrief(_ data: Data) throws -> PathBrief {
        let entry = try JSONDecoder().decode(BriefEntry.self, from: data)
        let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return PathBrief(text: text) }
        let parts = [entry.what, entry.dependents, entry.ifDeleted]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return PathBrief(text: parts.joined(separator: "\n\n"))
    }

    static func parseVerdicts(_ data: Data) throws -> [String: LeftoverVerdict] {
        let entries = try JSONDecoder().decode([String: VerdictEntry].self, from: data)
        return entries.mapValues { entry in
            let note = entry.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = [entry.what, entry.dependents, entry.ifDeleted]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return LeftoverVerdict(
                kind: LeftoverVerdictKind(rawValue: entry.verdict ?? "") ?? .unsure,
                note: note.isEmpty ? fallback : note
            )
        }
    }

    private static func name(of category: SweepCategory) -> String {
        switch category {
        case .cleanable(let c): c.rawValue
        case .report(let r): r.rawValue
        }
    }

    private struct Completion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct Entry: Decodable {
        let level: String?
        let explanation: String?
    }

    private struct BriefEntry: Decodable {
        let text: String?
        let what: String?
        let dependents: String?
        let ifDeleted: String?
    }

    private struct VerdictEntry: Decodable {
        let verdict: String?
        let note: String?
        let what: String?
        let dependents: String?
        let ifDeleted: String?
    }
}

enum ReviewFailure: Error, CustomStringConvertible {
    case notHTTP
    case status(Int)
    case emptyReply

    var description: String {
        switch self {
        case .notHTTP: "not an HTTP response"
        case .status(let code): "HTTP \(code)"
        case .emptyReply: "empty reply"
        }
    }
}
