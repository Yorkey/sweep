import Foundation

enum BrowserKind: CaseIterable {
    case safari, chrome, firefox, edge, arc

    var displayName: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .firefox: "Firefox"
        case .edge: "Edge"
        case .arc: "Arc"
        }
    }

    var cachePaths: [String] {
        switch self {
        case .safari: ["Library/Caches/com.apple.Safari"]
        case .chrome: ["Library/Caches/Google/Chrome", "Library/Caches/com.google.Chrome"]
        case .firefox: ["Library/Caches/Firefox"]
        case .edge: ["Library/Caches/Microsoft Edge"]
        case .arc: ["Library/Caches/company.thebrowser.Browser"]
        }
    }
}

enum DevCache: CaseIterable {
    case derivedData, homebrew, npm, pip, yarn, cargo

    var displayName: String {
        switch self {
        case .derivedData: "Xcode DerivedData"
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .pip: "pip"
        case .yarn: "Yarn"
        case .cargo: "Cargo registry"
        }
    }

    var path: String {
        switch self {
        case .derivedData: "Library/Developer/Xcode/DerivedData"
        case .homebrew: "Library/Caches/Homebrew"
        case .npm: ".npm"
        case .pip: "Library/Caches/pip"
        case .yarn: "Library/Caches/Yarn"
        case .cargo: ".cargo/registry/cache"
        }
    }
}

struct Locator {
    static let installerAge: TimeInterval = 14 * 24 * 60 * 60
    static let largeFileDirectoryCap = 20_000

    let environment: SweepEnvironment
    let home: String
    let zones: ProtectedZones
    private let fileManager = FileManager.default

    init(environment: SweepEnvironment) {
        self.environment = environment
        home = Paths.real(environment.home.path) ?? environment.home.standardizedFileURL.path
        zones = ProtectedZones(home: home)
    }

    func findings(for category: SweepCategory, skipped: inout [SkippedLocation]) throws -> [Finding] {
        switch category {
        case .cleanable(let c): try cleanables(c, skipped: &skipped).map(Finding.cleanable)
        case .report(.trash): try trashReport(skipped: &skipped).map { [.report($0)] } ?? []
        case .report(.largeFiles): try largeFiles(skipped: &skipped).map(Finding.report)
        }
    }

    private func cleanables(_ category: CleanableCategory, skipped: inout [SkippedLocation]) throws -> [Cleanable] {
        var result: [Cleanable] = []
        for (url, name, root) in candidates(category, skipped: &skipped) {
            try Task.checkCancellation()
            guard let target = Admission.admit(url, into: root, zones: zones) else { continue }
            let display = displayPath(target.path)
            result.append(Cleanable(
                id: CleanableID(raw: "\(category.rawValue):\(display)"),
                category: category,
                displayName: name,
                displayPath: display,
                bytes: try measure(target.path, skipped: &skipped),
                risk: AssessedRisk(rule: .of(.cleanable(category))),
                target: target
            ))
        }
        return result
    }

    private func candidates(_ category: CleanableCategory, skipped: inout [SkippedLocation]) -> [(URL, String, AllowedRoot)] {
        switch category {
        case .userCaches:
            let caches = "Library/Caches"
            let claimed = Set((BrowserKind.allCases.flatMap(\.cachePaths) + DevCache.allCases.map(\.path))
                .compactMap { topLevelChild(of: caches, in: $0) })
            return children(of: caches, skipped: &skipped)
                .filter { !claimed.contains($0.lastPathComponent) }
                .map { ($0, $0.lastPathComponent, rootInside(caches)) }
        case .userLogs:
            let logs = "Library/Logs"
            return children(of: logs, skipped: &skipped).map { ($0, $0.lastPathComponent, rootInside(logs)) }
        case .oldInstallers:
            let downloads = "Downloads"
            let cutoff = environment.now.addingTimeInterval(-Self.installerAge)
            return children(of: downloads, skipped: &skipped)
                .filter { url in
                    guard Self.looksLikeInstaller(url.lastPathComponent),
                          let entry = Probe(url.path).stat, entry.isRegular
                    else { return false }
                    return entry.modified < cutoff
                }
                .map { ($0, $0.lastPathComponent, rootInside(downloads)) }
        case .devCaches:
            return DevCache.allCases.compactMap { cache in
                existing(cache.path).map { ($0, cache.displayName, rootExactly(cache.path)) }
            }
        case .browserCaches:
            return BrowserKind.allCases.flatMap { browser in
                browser.cachePaths.compactMap { path in
                    existing(path).map { ($0, browser.displayName, rootExactly(path)) }
                }
            }
        }
    }

    static func looksLikeInstaller(_ name: String) -> Bool {
        switch (name as NSString).pathExtension.lowercased() {
        case "dmg", "pkg": true
        case "zip": ["installer", "setup", "安装"].contains { name.lowercased().contains($0) }
        default: false
        }
    }

    private func trashReport(skipped: inout [SkippedLocation]) throws -> Report? {
        let path = home + "/.Trash"
        guard let entry = Probe(path).stat, entry.isDirectory else { return nil }
        return report(.trash, path: path, name: ".Trash", bytes: try measure(path, skipped: &skipped))
    }

    private func largeFiles(skipped: inout [SkippedLocation]) throws -> [Report] {
        let excluded = Set(["Library", ".Trash"].map { home + "/" + $0 })
        let prunedNames: Set<String> = ["node_modules", ".git"]
        var failures: [SkippedLocation] = []
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: home),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { url, error in
                failures.append(SkippedLocation(path: url.path, reason: error.localizedDescription))
                return true
            }
        ) else { return [] }

        var reports: [Report] = []
        var directories = 0
        while let url = walker.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true { continue }
            let path = url.path
            if values?.isDirectory == true {
                if excluded.contains(path) || prunedNames.contains(url.lastPathComponent) || zones.covers(path) {
                    walker.skipDescendants()
                    continue
                }
                directories += 1
                if directories >= Self.largeFileDirectoryCap {
                    skipped.append(SkippedLocation(path: displayPath(home), reason: "目录数量超过 \(Self.largeFileDirectoryCap)，停止查找大文件"))
                    break
                }
                continue
            }
            guard values?.isRegularFile == true, let size = values?.fileSize.map(Int64.init),
                  size >= environment.largeFileThreshold, !zones.covers(path)
            else { continue }
            reports.append(report(.largeFiles, path: path, name: url.lastPathComponent, bytes: size))
        }
        skipped += failures
        return reports
    }

    private func report(_ category: ReportCategory, path: String, name: String, bytes: Int64) -> Report {
        let display = displayPath(path)
        return Report(
            id: ReportID(raw: "\(category.rawValue):\(display)"),
            category: category,
            displayName: name,
            displayPath: display,
            bytes: bytes,
            risk: AssessedRisk(rule: .of(.report(category))),
            revealURL: URL(fileURLWithPath: path)
        )
    }

    private func measure(_ path: String, skipped: inout [SkippedLocation]) throws -> Int64 {
        guard let entry = Probe(path).stat else { return 0 }
        if entry.isRegular { return entry.size }
        guard entry.isDirectory else { return 0 }
        var failures: [SkippedLocation] = []
        guard let walker = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [],
            errorHandler: { url, error in
                failures.append(SkippedLocation(path: url.path, reason: error.localizedDescription))
                return true
            }
        ) else { return 0 }
        var total: Int64 = 0
        while let url = walker.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        skipped += failures.map { SkippedLocation(path: displayPath($0.path), reason: $0.reason) }
        return total
    }

    private func children(of relative: String, skipped: inout [SkippedLocation]) -> [URL] {
        let url = URL(fileURLWithPath: home + "/" + relative)
        guard case .present = Probe(url.path) else { return [] }
        do {
            return try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            skipped.append(SkippedLocation(path: "~/" + relative, reason: error.localizedDescription))
            return []
        }
    }

    private func existing(_ relative: String) -> URL? {
        let path = home + "/" + relative
        guard case .present = Probe(path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func topLevelChild(of container: String, in relative: String) -> String? {
        guard relative.hasPrefix(container + "/") else { return nil }
        return relative.dropFirst(container.count + 1).split(separator: "/").first.map(String.init)
    }

    private func rootInside(_ relative: String) -> AllowedRoot {
        .inside(Paths.real(home + "/" + relative) ?? home + "/" + relative)
    }

    private func rootExactly(_ relative: String) -> AllowedRoot {
        .exactly(home + "/" + relative)
    }

    private func displayPath(_ path: String) -> String {
        if path == home { return "~" }
        if Paths.isStrictlyInside(path, home) { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }
}
