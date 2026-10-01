import Darwin
import Foundation

struct FileIdentity: Sendable, Hashable {
    let device: UInt64
    let inode: UInt64
}

struct FileStat: Sendable {
    let identity: FileIdentity
    let isSymlink: Bool
    let isDirectory: Bool
    let isRegular: Bool
    let size: Int64
    let modified: Date
}

enum Probe {
    case present(FileStat)
    case missing
    case unreadable(String)

    init(_ path: String) {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else {
            let code = errno
            self = (code == ENOENT || code == ENOTDIR) ? .missing : .unreadable(String(cString: strerror(code)))
            return
        }
        let kind = st.st_mode & S_IFMT
        self = .present(FileStat(
            identity: FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino)),
            isSymlink: kind == S_IFLNK,
            isDirectory: kind == S_IFDIR,
            isRegular: kind == S_IFREG,
            size: Int64(st.st_size),
            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        ))
    }

    var stat: FileStat? {
        if case .present(let s) = self { s } else { nil }
    }
}

enum Paths {
    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func isStrictlyInside(_ path: String, _ root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// Where a category is allowed to reach. Stored resolved so admission and recheck compare real paths.
enum AllowedRoot: Sendable, Hashable {
    case inside(String)
    case exactly(String)

    func admits(_ resolved: String) -> Bool {
        switch self {
        case .inside(let root): Paths.isStrictlyInside(resolved, root)
        case .exactly(let root): resolved == root
        }
    }
}

struct ProtectedZones: Sendable {
    let roots: [String]

    init(home: String) {
        let system = ["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications"]
        let personal = ["Documents", "Desktop", "Pictures", "Library/Mail", "Library/Containers/com.apple.mail"]
            .map { home + "/" + $0 }
        roots = (system + personal).map { Paths.real($0) ?? $0 }
    }

    /// Also true for an ancestor of a zone, because moving the ancestor moves the zone.
    func covers(_ resolved: String) -> Bool {
        roots.contains { zone in
            resolved == zone || Paths.isStrictlyInside(resolved, zone) || Paths.isStrictlyInside(zone, resolved)
        }
    }
}

/// Minted only by `Admission.admit`.
struct CleanTarget: Sendable {
    let path: String
    let identity: FileIdentity
    let root: AllowedRoot
}

enum Admission {
    static func admit(_ url: URL, into root: AllowedRoot, zones: ProtectedZones) -> CleanTarget? {
        guard let entry = Probe(url.path).stat, !entry.isSymlink,
              let resolved = Paths.real(url.path),
              root.admits(resolved), !zones.covers(resolved),
              let pinned = Probe(resolved).stat, !pinned.isSymlink
        else { return nil }
        return CleanTarget(path: resolved, identity: pinned.identity, root: root)
    }

    /// Nil means the target is still exactly what was admitted.
    static func recheck(_ target: CleanTarget, zones: ProtectedZones) -> CleanOutcome? {
        let entry: FileStat
        switch Probe(target.path) {
        case .missing: return .alreadyGone
        case .unreadable(let reason): return .failed(reason)
        case .present(let s): entry = s
        }
        if entry.isSymlink { return .changedSinceScan }
        guard let resolved = Paths.real(target.path) else { return .alreadyGone }
        if !target.root.admits(resolved) || zones.covers(resolved) { return .refusedProtected }
        if resolved != target.path || entry.identity != target.identity { return .changedSinceScan }
        return nil
    }

    static func move(_ target: CleanTarget, to destination: TrashDestination) -> CleanOutcome {
        let source = URL(fileURLWithPath: target.path)
        switch destination {
        case .system:
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: source, resultingItemURL: &resulting)
                return .moved(to: (resulting as URL?) ?? source)
            } catch {
                return .failed(error.localizedDescription)
            }
        case .directory(let directory):
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                return .failed(error.localizedDescription)
            }
            var destinationURL = directory.appendingPathComponent(source.lastPathComponent)
            if case .present = Probe(destinationURL.path) {
                destinationURL = directory.appendingPathComponent("\(source.lastPathComponent)-\(target.identity.inode)")
            }
            guard renamex_np(source.path, destinationURL.path, UInt32(RENAME_EXCL)) == 0 else {
                return .failed(String(cString: strerror(errno)))
            }
            return .moved(to: destinationURL)
        }
    }
}
