import AppKit
import LocalAuthentication
import Observation
import Security
import SwiftUI
import SweepCore

@main
struct SweepMain: App {
    @State private var model = AppModel()

    init() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("清扫") {
            ContentView()
                .environment(model)
                .frame(minWidth: 680, minHeight: 480)
        }
    }
}

enum WorkspacePane: String, CaseIterable, Identifiable, Hashable {
    case clean, residue
    var id: String { rawValue }
    var title: String { self == .clean ? "清理" : "残留" }
}

struct ShownBrief: Identifiable {
    let id = UUID()
    let title: String
    let brief: PathBrief
}

enum SettingsKey {
    static let legacyAPIKey = "apiKey"
    static let baseURL = "baseURL"
    static let model = "model"
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"
    static let jevBaseURL = "jevBaseURL"
    static let jevModel = "jevModel"
    static let defaultJevBaseURL = "https://api.typesafe.ai/v1"
    static let defaultJevModel = "jev-latest"
}

enum APIKeyStore {
    private static func fileURL(_ name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.sweep.app/\(name)")
    }

    static func load(file name: String = "api-key") -> String? {
        if let stored = readFile(name) { return stored }
        guard name == "api-key" else { return nil }
        if let legacy = UserDefaults.standard.string(forKey: SettingsKey.legacyAPIKey) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                save(trimmed, file: name)
                UserDefaults.standard.removeObject(forKey: SettingsKey.legacyAPIKey)
                return trimmed
            }
        }
        guard let migrated = silentKeychainRead() else { return nil }
        save(migrated, file: name)
        silentKeychainDelete()
        return migrated
    }

    static func save(_ value: String, file name: String = "api-key") {
        let url = fileURL(name)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(trimmed.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readFile(_ name: String) -> String? {
        guard let data = try? Data(contentsOf: fileURL(name)),
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Reads the old login-keychain item only when macOS can do it without a password dialog.
    private static func silentKeychainRead() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.sweep.app",
            kSecAttrAccount as String: "apiKey",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: silentContext(),
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func silentKeychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "local.sweep.app",
            kSecAttrAccount as String: "apiKey",
            kSecUseAuthenticationContext as String: silentContext(),
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func silentContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}

@MainActor
@Observable
final class AppModel {
    var pane: WorkspacePane = .clean
    var plan: SweepPlan?
    var selection = Selection()
    var isScanning = false
    var isCleaning = false
    var movedBytes: Int64?
    var residue: ResidueSurvey?
    var verdicts: [String: LeftoverVerdict] = [:]
    var residueSelection: Set<String> = []
    var isSurveying = false
    var isJudging = false
    var residueNote: String?
    var shownBrief: ShownBrief?
    var explainError: String?
    var isExplaining = false
    private var sweep: Sweep?

    var residuePicked: [PickedLeftover] {
        guard let residue else { return [] }
        return residue.candidates.compactMap { candidate in
            guard residueSelection.contains(candidate.id), let verdict = verdicts[candidate.id] else { return nil }
            return PickedLeftover(candidate, verdict: verdict)
        }
    }

    func scan() {
        guard !isScanning else { return }
        var environment = SweepEnvironment.live()
        environment.reviewer = Self.savedRouter()
        let sweep = Sweep(environment: environment)
        self.sweep = sweep
        isScanning = true
        Task {
            defer { isScanning = false }
            do {
                for try await snapshot in await sweep.scan() {
                    plan = snapshot
                }
            } catch {}
        }
    }

    func clean() {
        guard let plan, let sweep, !isCleaning else { return }
        let order = plan.order(for: selection)
        guard order.count > 0 else { return }
        isCleaning = true
        Task {
            let report = await sweep.clean(order)
            movedBytes = report.movedBytes
            isCleaning = false
            scan()
        }
    }

    func explain(_ finding: Finding) {
        ask(title: finding.displayName) { try await $0.explain(finding) }
    }

    func explain(_ candidate: LeftoverCandidate) {
        ask(title: candidate.displayName) { try await $0.explain(candidate) }
    }

    private func ask(title: String, load: @escaping (ModelRouter) async throws -> PathBrief) {
        guard !isExplaining else { return }
        guard let reviewer = Self.savedRouter() else {
            explainError = "未配置 API Key，无法询问模型。"
            return
        }
        isExplaining = true
        Task {
            defer { isExplaining = false }
            do {
                shownBrief = ShownBrief(title: title, brief: try await load(reviewer))
            } catch {
                explainError = "询问失败。\(error)"
            }
        }
    }

    func surveyResidue() {
        guard !isSurveying else { return }
        isSurveying = true
        residueNote = nil
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let survey = Residue.survey(home: home, applicationDirectories: Residue.liveApplicationDirectories(home: home))
            residue = survey
            verdicts = [:]
            residueSelection = []
            isSurveying = false
            await judge(survey)
        }
    }

    func judgeResidue() {
        guard let residue, !isJudging, !isSurveying else { return }
        Task { await judge(residue) }
    }

    private func judge(_ survey: ResidueSurvey) async {
        guard !survey.candidates.isEmpty, !isJudging else { return }
        guard let reviewer = Self.savedRouter() else {
            residueNote = "未配置 API Key。候选已经列出，判断需要在设置里填写钥匙。"
            return
        }
        isJudging = true
        residueNote = nil
        defer { isJudging = false }
        do {
            let result = try await reviewer.judge(survey)
            verdicts = result
            let asked = survey.candidates.prefix(Residue.judgeLimit)
            let matched = asked.filter { result[$0.id] != nil }.count
            if matched == 0 {
                residueNote = "判断结束，但没有对上任何一项。请检查 Jev 或生成模型的配置。"
            }
        } catch {
            residueNote = "模型判断失败。\(error)"
        }
    }

    func cleanResidue() {
        let picked = residuePicked
        guard !picked.isEmpty, !isCleaning else { return }
        isCleaning = true
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let moves = Residue.move(picked, to: .system, home: home)
            movedBytes = moves.reduce(0) { sum, move in
                guard case .moved = move.outcome,
                      let bytes = residue?.candidates.first(where: { $0.id == move.id })?.bytes
                else { return sum }
                return sum + bytes
            }
            isCleaning = false
            residueSelection = []
            surveyResidue()
        }
    }

    private static func savedRouter() -> ModelRouter? {
        let defaults = UserDefaults.standard
        let base = defaults.string(forKey: SettingsKey.baseURL).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? URL(string: SettingsKey.defaultBaseURL)!
        let model = defaults.string(forKey: SettingsKey.model).flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKey.defaultModel
        let chat = ModelReviewer(apiKey: APIKeyStore.load(), baseURL: base, model: model)
        let jevBase = defaults.string(forKey: SettingsKey.jevBaseURL).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            ?? URL(string: SettingsKey.defaultJevBaseURL)!
        let jevModel = defaults.string(forKey: SettingsKey.jevModel).flatMap { $0.isEmpty ? nil : $0 } ?? SettingsKey.defaultJevModel
        let jev = JevJudge(apiKey: APIKeyStore.load(file: "jev-api-key"), baseURL: jevBase, model: jevModel)
        let router = ModelRouter(chat: chat, jev: jev)
        return router.canJudge || router.canExplain ? router : nil
    }
}
