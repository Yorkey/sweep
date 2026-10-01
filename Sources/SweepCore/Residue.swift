import Foundation

public struct PathBrief: Sendable, Equatable {
    public let text: String
}

public struct InstalledApp: Sendable, Equatable, Identifiable {
    public let name: String
    public let bundleIdentifier: String
    public var id: String { bundleIdentifier }
}

public enum ResiduePlace: String, Sendable, CaseIterable {
    case applicationSupport
    case caches
    case preferences
    case logs
    case savedState
    case containers
    case httpStorages
    case webkit
    case scripts

    var relative: String {
        switch self {
        case .applicationSupport: "Library/Application Support"
        case .caches: "Library/Caches"
        case .preferences: "Library/Preferences"
        case .logs: "Library/Logs"
        case .savedState: "Library/Saved Application State"
        case .containers: "Library/Containers"
        case .httpStorages: "Library/HTTPStorages"
        case .webkit: "Library/WebKit"
        case .scripts: "Library/Application Scripts"
        }
    }

    var label: String {
        switch self {
        case .applicationSupport: "应用支持"
        case .caches: "缓存"
        case .preferences: "偏好设置"
        case .logs: "日志"
        case .savedState: "保存的应用状态"
        case .containers: "容器"
        case .httpStorages: "网络存储"
        case .webkit: "网页缓存"
        case .scripts: "应用脚本"
        }
    }
}

public struct LeftoverCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let place: ResiduePlace
    public let displayName: String
    public let displayPath: String
    public let bytes: Int64
    public let revealURL: URL
    public var canMove: Bool { target != nil }
    let target: CleanTarget?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.bytes == rhs.bytes && lhs.canMove == rhs.canMove
    }
}

public enum LeftoverVerdictKind: String, Sendable, Equatable {
    case leftover, keep, unsure
}

public struct LeftoverVerdict: Sendable, Equatable {
    public let kind: LeftoverVerdictKind
    public let note: String
}

/// Only a model verdict of `.leftover` with an admitted path can be built.
public struct PickedLeftover: Sendable {
    public let id: String
    public let bytes: Int64
    let candidate: LeftoverCandidate

    public init?(_ candidate: LeftoverCandidate, verdict: LeftoverVerdict) {
        guard verdict.kind == .leftover, candidate.target != nil else { return nil }
        self.id = candidate.id
        self.bytes = candidate.bytes
        self.candidate = candidate
    }
}

public struct LeftoverMove: Sendable {
    public let id: String
    public let outcome: CleanOutcome
}

public struct ResidueSurvey: Sendable {
    public let installed: [InstalledApp]
    public let candidates: [LeftoverCandidate]
    public let truncated: Bool
}

public enum Residue {
    public static let judgeLimit = 60

    public static func liveApplicationDirectories(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
        ]
    }

    public static func survey(home: URL, applicationDirectories: [URL]) -> ResidueSurvey {
        let homePath = Paths.real(home.path) ?? home.standardizedFileURL.path
        let zones = ProtectedZones(home: homePath)
        let installed = applicationDirectories.flatMap { apps(in: $0, depth: 0) }
        let index = InstalledIndex(installed)
        var candidates: [LeftoverCandidate] = []
        for place in ResiduePlace.allCases {
            let root = homePath + "/" + place.relative
            guard case .present(let entry) = Probe(root), entry.isDirectory, !entry.isSymlink else { continue }
            let allowed = AllowedRoot.inside(Paths.real(root) ?? root)
            for url in children(of: root) {
                let name = url.lastPathComponent
                guard isCandidate(name, place: place, index: index) else { continue }
                guard let stat = Probe(url.path).stat, !stat.isSymlink else { continue }
                let target = Admission.admit(url, into: allowed, zones: zones)
                let resolved = target?.path ?? (Paths.real(url.path) ?? url.path)
                let display = displayPath(resolved, home: homePath)
                candidates.append(LeftoverCandidate(
                    id: display,
                    place: place,
                    displayName: name,
                    displayPath: display,
                    bytes: byteCount(resolved),
                    revealURL: URL(fileURLWithPath: resolved),
                    target: target
                ))
            }
        }
        let sorted = candidates.sorted { $0.bytes > $1.bytes }
        return ResidueSurvey(
            installed: installed,
            candidates: Array(sorted.prefix(judgeLimit)),
            truncated: sorted.count > judgeLimit
        )
    }

    public static func move(
        _ picked: [PickedLeftover],
        to destination: TrashDestination,
        home: URL
    ) -> [LeftoverMove] {
        let homePath = Paths.real(home.path) ?? home.standardizedFileURL.path
        let zones = ProtectedZones(home: homePath)
        return picked.compactMap { item in
            guard let target = item.candidate.target else { return nil }
            let outcome = Admission.recheck(target, zones: zones) ?? Admission.move(target, to: destination)
            return LeftoverMove(id: item.id, outcome: outcome)
        }
    }

    static func identity(_ name: String) -> String {
        if name.hasSuffix(".savedState") { return String(name.dropLast(".savedState".count)) }
        if name.hasSuffix(".plist") { return String(name.dropLast(".plist".count)) }
        return name
    }

    private static func isCandidate(_ name: String, place: ResiduePlace, index: InstalledIndex) -> Bool {
        if name.hasPrefix(".") { return false }
        let key = identity(name)
        if index.owns(key) { return false }
        if looksLikeBundleID(key) {
            let lower = key.lowercased()
            if lower.hasPrefix("com.apple.") || lower.hasPrefix("group.com.apple.") { return false }
            return true
        }
        guard place == .applicationSupport || place == .caches else { return false }
        let folded = key.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return folded.count >= 3 && !systemFolderNames.contains(folded)
    }

    private static func looksLikeBundleID(_ key: String) -> Bool {
        let parts = key.split(separator: ".")
        guard parts.count >= 2, let head = parts.first else { return false }
        return ["com", "org", "net", "io", "me", "app", "dev"].contains(head.lowercased())
            || key.lowercased().hasPrefix("group.")
    }

    /// Folders macOS creates itself. A bare name here is not an uninstalled app.
    private static let systemFolderNames: Set<String> = [
        "addressbook", "crashreporter", "knowledge", "mobilesync", "cookies",
        "audiounits", "components", "quicklook", "spotlight", "diagnostics",
        "icloud", "cloudkit", "familycircled", "gamekit", "suggestions",
        "differentialprivacy", "homed", "passbook", "siri", "homekit",
    ]

    private static func apps(in directory: URL, depth: Int) -> [InstalledApp] {
        guard depth < 2,
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
              )
        else { return [] }
        var found: [InstalledApp] = []
        for child in children {
            if child.pathExtension == "app" {
                if let app = readApp(at: child) { found.append(app) }
            } else if depth == 0 {
                found += apps(in: child, depth: 1)
            }
        }
        return found
    }

    private static func readApp(at url: URL) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plistURL),
              let bundleID = dict["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty
        else { return nil }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(name: name, bundleIdentifier: bundleID)
    }

    private static func children(of path: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private static func byteCount(_ path: String) -> Int64 {
        guard let entry = Probe(path).stat, !entry.isSymlink else { return 0 }
        if entry.isRegular { return entry.size }
        guard entry.isDirectory,
              let walker = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: nil
              )
        else { return 0 }
        var total: Int64 = 0
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if seen > 8_000 { break }
            guard let stat = Probe(url.path).stat else { continue }
            if stat.isSymlink {
                walker.skipDescendants()
                continue
            }
            if stat.isRegular { total += stat.size }
        }
        return total
    }

    private static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if Paths.isStrictlyInside(path, home) { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}

private struct InstalledIndex {
    let bundleIDs: Set<String>
    let names: Set<String>

    init(_ apps: [InstalledApp]) {
        bundleIDs = Set(apps.map { $0.bundleIdentifier.lowercased() })
        names = Set(apps.map { Self.fold($0.name) })
    }

    func owns(_ key: String) -> Bool {
        let lower = key.lowercased()
        if bundleIDs.contains(lower) { return true }
        if lower.hasPrefix("group."), bundleIDs.contains(String(lower.dropFirst("group.".count))) { return true }
        return names.contains(Self.fold(key))
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { !$0.isWhitespace }
    }
}
