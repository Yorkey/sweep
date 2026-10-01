import Foundation
import Testing
@testable import SweepCore

@Suite struct Locating {
    @Test func cacheDirectoryIsCleanableAndDocumentsIsNot() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob.bin", bytes: 100)
        try fx.file("Library/Caches/com.example.app/nested/more.bin", bytes: 23)
        try fx.file("Documents/thesis.txt", bytes: 50)

        let plan = try await finalPlan(fx.environment(threshold: 1))

        guard case .cleanable(let cache)? = plan.finding(at: "~/Library/Caches/com.example.app") else {
            Issue.record("cache finding missing, got \(plan.displayPaths)")
            return
        }
        #expect(cache.category == .userCaches)
        #expect(cache.bytes == 123)
        #expect(cache.risk.level == .low)
        #expect(plan.displayPaths.allSatisfy { !$0.contains("Documents") })
    }

    @Test func symlinkIntoDocumentsNeverBecomesAFinding() async throws {
        let fx = try Fixture()
        try fx.file("Documents/secret.txt", bytes: 40)
        try fx.file("Desktop/todo.txt", bytes: 40)
        try fx.symlink("Library/Caches/sneaky", to: "Documents")
        try fx.symlink("Library/Logs", to: "Desktop")
        try fx.symlink("Downloads", to: "Documents")
        try fx.file("Documents/Old.dmg", bytes: 40, modified: fx.now.addingTimeInterval(-30 * 86_400))

        let plan = try await finalPlan(fx.environment(threshold: 1))

        #expect(plan.displayPaths == [])
        #expect(plan.order(for: Selection()).count == 0)
    }

    @Test func browserCacheIsLowAndNotSelectedByDefault() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.apple.Safari/Cache.db", bytes: 64)
        try fx.file("Library/Caches/Google/Chrome/Default/data", bytes: 32)

        let plan = try await finalPlan(fx.environment())

        let browser = plan.groups.first { $0.category == .cleanable(.browserCaches) }
        #expect(browser?.findings.map(\.risk.level) == [.low, .low])
        #expect(plan.groups.map(\.category) == [.cleanable(.browserCaches)])
        #expect(plan.order(for: Selection()).count == 0)
        #expect(plan.selectedBytes(Selection()) == 0)
    }

    @Test func largeFileRespectsThresholdAndIsReportOnly() async throws {
        let fx = try Fixture()
        try fx.file("Movies/clip.bin", bytes: 2)

        let atDefault = try await finalPlan(fx.environment())
        #expect(atDefault.finding(at: "~/Movies/clip.bin") == nil)

        let atOne = try await finalPlan(fx.environment(threshold: 1))
        guard case .report(let report)? = atOne.finding(at: "~/Movies/clip.bin") else {
            Issue.record("large file report missing, got \(atOne.displayPaths)")
            return
        }
        #expect(report.category == .largeFiles)
        #expect(report.bytes == 2)
        #expect(atOne.order(for: Selection()).count == 0)
    }

    @Test func trashIsAHighRiskReport() async throws {
        let fx = try Fixture()
        try fx.file(".Trash/old.txt", bytes: 7)

        let plan = try await finalPlan(fx.environment())

        guard case .report(let report)? = plan.finding(at: "~/.Trash") else {
            Issue.record("trash report missing, got \(plan.displayPaths)")
            return
        }
        #expect(report.category == .trash)
        #expect(report.bytes == 7)
        #expect(report.risk.level == .high)
        #expect(plan.order(for: Selection()).count == 0)
    }

    @Test func oldInstallersNeedAgeAndAnInstallerName() async throws {
        let fx = try Fixture()
        let old = fx.now.addingTimeInterval(-15 * 86_400)
        try fx.file("Downloads/Tool.dmg", modified: old)
        try fx.file("Downloads/Fresh.pkg", modified: fx.now.addingTimeInterval(-86_400))
        try fx.file("Downloads/AppSetup.zip", modified: old)
        try fx.file("Downloads/photos.zip", modified: old)

        let plan = try await finalPlan(fx.environment())

        let installers = plan.groups.first { $0.category == .cleanable(.oldInstallers) }
        #expect(installers?.findings.map(\.id) == ["oldInstallers:~/Downloads/AppSetup.zip", "oldInstallers:~/Downloads/Tool.dmg"])
        #expect(installers?.findings.map(\.risk.level) == [.medium, .medium])
        #expect(plan.order(for: Selection()).count == 0)
    }

    @Test func symlinkInsideACacheDoesNotCountTheTarget() async throws {
        let fx = try Fixture()
        try fx.file("Documents/secret.txt", bytes: 5_000)
        try fx.file("Library/Caches/com.example.app/own.bin", bytes: 10)
        try fx.symlink("Library/Caches/com.example.app/alias", to: "Documents/secret.txt")
        try fx.symlink("Library/Caches/com.example.app/docs", to: "Documents")

        let plan = try await finalPlan(fx.environment())
        guard case .cleanable(let cache)? = plan.finding(at: "~/Library/Caches/com.example.app") else {
            Issue.record("cache finding missing, got \(plan.displayPaths)")
            return
        }
        #expect(cache.bytes == 10)
        #expect(plan.displayPaths.allSatisfy { !$0.contains("Documents") })
    }

    @Test func devCachesAreSafeAndNotDoubleCountedAsUserCaches() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/Homebrew/bottle.tar", bytes: 5)
        try fx.file(".npm/_cacache/index", bytes: 6)

        let plan = try await finalPlan(fx.environment())

        #expect(plan.groups.map(\.category) == [.cleanable(.devCaches)])
        #expect(plan.displayPaths == ["~/Library/Caches/Homebrew", "~/.npm"])
        #expect(plan.order(for: Selection()).allLevels == [.safe, .safe])
    }
}

@Suite struct Selecting {
    @Test func overridesWinAndResetRestoresDefault() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob", bytes: 10)
        try fx.file("Library/Caches/com.apple.Safari/Cache.db", bytes: 20)
        let plan = try await finalPlan(fx.environment())
        let app = try #require(plan.cleanables.first { $0.displayPath == "~/Library/Caches/com.example.app" })
        let safari = try #require(plan.cleanables.first { $0.displayPath == "~/Library/Caches/com.apple.Safari" })

        var selection = Selection()
        #expect(plan.selectedBytes(selection) == 10)
        selection.set(app.id, selected: false)
        selection.set(safari.id, selected: true)
        #expect(plan.selectedBytes(selection) == 20)
        #expect(plan.order(for: selection).allLevels == [.low])
        selection.resetToDefault()
        #expect(plan.selectedBytes(selection) == 10)
    }

    @Test func snapshotsArrivePerCategoryAndGrow() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        try fx.file("Library/Logs/app.log")

        let plans = try await collect(Sweep(environment: fx.environment()).scan())

        #expect(plans.count == SweepCategory.allCases.count)
        #expect(plans.map { $0.groups.count } == [1, 2, 2, 2, 2, 2, 2])
        #expect(plans.map(\.assessment).allSatisfy { $0 == .rulesOnly(.noAPIKey) })
    }
}

@Suite struct Cleaning {
    @Test func cleanMovesIntoFixtureTrashAndConvergesOnRerun() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob", bytes: 11)
        let sweep = Sweep(environment: fx.environment())
        let plan = try #require(try await collect(sweep.scan()).last)
        let order = plan.order(for: Selection())
        #expect(order.count == 1)

        let first = await sweep.clean(order)
        let destination = fx.trash.appendingPathComponent("com.example.app")
        guard case .moved(let movedTo)? = first.outcomes.values.first else {
            Issue.record("expected a move, got \(first.outcomes)")
            return
        }
        #expect(movedTo.path == destination.path)
        #expect(first.movedBytes == 11)
        #expect(first.converged)
        #expect(!fx.exists("Library/Caches/com.example.app"))
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("blob").path))

        let second = await sweep.clean(order)
        #expect(second.outcomes.values.map { $0 } == [.alreadyGone])
        #expect(second.movedBytes == 0)
        #expect(second.converged)
    }

    @Test func partialMoveConvergesOnTheNextClean() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/one/a", bytes: 3)
        try fx.file("Library/Caches/two/b", bytes: 4)
        let sweep = Sweep(environment: fx.environment())
        let order = try #require(try await collect(sweep.scan()).last).order(for: Selection())
        #expect(order.count == 2)

        try FileManager.default.createDirectory(at: fx.trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: fx.home.appendingPathComponent("Library/Caches/one"),
            to: fx.trash.appendingPathComponent("one")
        )

        let report = await sweep.clean(order)
        let outcomes = Array(report.outcomes.values)
        #expect(outcomes.contains(.alreadyGone))
        #expect(outcomes.contains { if case .moved = $0 { true } else { false } })
        #expect(report.converged)
        #expect(!fx.exists("Library/Caches/two"))

        let again = await sweep.clean(order)
        #expect(again.outcomes.values.allSatisfy { $0 == .alreadyGone })
        #expect(again.converged)
    }

    @Test func replacedItemIsNotMoved() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        let sweep = Sweep(environment: fx.environment())
        let order = try #require(try await collect(sweep.scan()).last).order(for: Selection())

        try FileManager.default.removeItem(at: fx.home.appendingPathComponent("Library/Caches/com.example.app"))
        try fx.file("Library/Caches/com.example.app/other")

        let report = await sweep.clean(order)
        #expect(report.outcomes.values.map { $0 } == [.changedSinceScan])
        #expect(!report.converged)
        #expect(fx.exists("Library/Caches/com.example.app/other"))
    }

    @Test func itemSwappedForSymlinkIntoDocumentsIsNotMoved() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        try fx.file("Documents/keep.txt")
        let sweep = Sweep(environment: fx.environment())
        let order = try #require(try await collect(sweep.scan()).last).order(for: Selection())

        try FileManager.default.removeItem(at: fx.home.appendingPathComponent("Library/Caches/com.example.app"))
        try fx.symlink("Library/Caches/com.example.app", to: "Documents")

        let report = await sweep.clean(order)
        #expect(report.outcomes.values.map { $0 } == [.changedSinceScan])
        #expect(fx.exists("Documents/keep.txt"))
    }

    @Test func parentSwappedForSymlinkIntoDocumentsIsRefused() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        try fx.file("Documents/com.example.app/keep.txt")
        let sweep = Sweep(environment: fx.environment())
        let order = try #require(try await collect(sweep.scan()).last).order(for: Selection())

        try FileManager.default.removeItem(at: fx.home.appendingPathComponent("Library/Caches"))
        try fx.symlink("Library/Caches", to: "Documents")

        let report = await sweep.clean(order)
        #expect(report.outcomes.values.map { $0 } == [.refusedProtected])
        #expect(fx.exists("Documents/com.example.app/keep.txt"))
    }
}

@Suite struct Reviewing {
    @Test func lowerProposalsNeverLowerTheLevel() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        try fx.file("Downloads/Tool.dmg", modified: fx.now.addingTimeInterval(-30 * 86_400))
        try fx.file(".Trash/old.txt")
        let reviewer = StubReviewer { _ in .safe }

        let plans = try await collect(Sweep(environment: fx.environment(reviewer: reviewer)).scan())
        let plan = try #require(plans.last)

        #expect(plans.dropLast().allSatisfy { $0.assessment == .rulesOnly(.reviewPending) })
        #expect(plan.assessment == .modelReviewed(model: "stub"))
        #expect(plan.allFindings.map(\.risk.level) == [.low, .medium, .high])
        #expect(plan.allFindings.map(\.risk.raisedTo) == [nil, nil, nil])
        #expect(plan.allFindings.map(\.risk.modelExplanation) == [
            "复核：~/Library/Caches/com.example.app", "复核：~/Downloads/Tool.dmg", "复核：~/.Trash",
        ])
    }

    @Test func higherProposalRaisesAndDropsDefaultSelection() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        try fx.file("Library/Logs/app.log")
        let reviewer = StubReviewer { $0.displayPath == "~/Library/Caches/com.example.app" ? .high : nil }

        let plan = try await finalPlan(fx.environment(reviewer: reviewer))

        let cache = try #require(plan.finding(at: "~/Library/Caches/com.example.app"))
        #expect(cache.risk.level == .high)
        #expect(cache.risk.rule.level == .low)
        #expect(plan.finding(at: "~/Library/Logs/app.log")?.risk.level == .safe)
        #expect(plan.order(for: Selection()).allLevels == [.safe])
    }

    @Test func failingReviewerKeepsRulePlan() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")

        let plan = try await finalPlan(fx.environment(reviewer: FailingReviewer()))

        guard case .rulesOnly(.reviewFailed) = plan.assessment else {
            Issue.record("expected reviewFailed, got \(plan.assessment)")
            return
        }
        #expect(plan.allFindings.map(\.risk.level) == [.low])
    }

    @Test func reviewItemsCarryOnlyHomeRelativePaths() async throws {
        let fx = try Fixture()
        try fx.file("Library/Caches/com.example.app/blob")
        try fx.file(".Trash/x")
        let seen = PathLog()
        let reviewer = StubReviewer { item in seen.append(item.displayPath); return nil }

        _ = try await finalPlan(fx.environment(reviewer: reviewer))

        #expect(seen.paths == ["~/Library/Caches/com.example.app", "~/.Trash"])
    }

    @Test func modelReviewerNeedsAKeyAndParsesTheReply() throws {
        let base = URL(string: "https://api.example.com/v1")!
        #expect(ModelReviewer(apiKey: nil, baseURL: base, model: "m") == nil)
        #expect(ModelReviewer(apiKey: "  ", baseURL: base, model: "m") == nil)
        #expect(ModelReviewer(apiKey: "sk-x", baseURL: base, model: "m")?.modelName == "m")

        let content = #"{"userCaches:~/Library/Caches/a": {"level": "high", "explanation": "含登录状态"}, "b": {"level": "bogus"}}"#
        let reply = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        let notes = try ModelReviewer.parse(Data(try ModelReviewer.messageContent(reply).utf8))

        #expect(notes["userCaches:~/Library/Caches/a"]?.proposed == .high)
        #expect(notes["userCaches:~/Library/Caches/a"]?.explanation == "含登录状态")
        #expect(notes["b"]?.proposed == nil)
    }
}

@Suite struct ResidueSurveys {
    @Test func uninstalledBundleIDIsACandidate() throws {
        let fx = try Fixture()
        let contents = fx.home.appendingPathComponent("Applications/Kept.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.example.kept", "CFBundleName": "Kept"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try fx.file("Library/Application Support/com.example.kept/data", bytes: 4)
        try fx.file("Library/Application Support/com.example.gone/data", bytes: 9)
        try fx.file("Library/Preferences/com.example.gone.plist", bytes: 2)
        try fx.file("Library/Application Support/com.apple.finder/data", bytes: 3)
        try fx.file("Library/Caches/CrashReporter/log", bytes: 1)
        try fx.file("Library/Application Support/Kept/state", bytes: 6)

        let survey = Residue.survey(
            home: fx.home,
            applicationDirectories: [fx.home.appendingPathComponent("Applications")]
        )

        #expect(survey.installed.map(\.bundleIdentifier) == ["com.example.kept"])
        let paths = survey.candidates.map(\.displayPath)
        #expect(paths.contains("~/Library/Application Support/com.example.gone"))
        #expect(paths.contains("~/Library/Preferences/com.example.gone.plist"))
        #expect(paths.allSatisfy { !$0.contains("com.example.kept") && !$0.contains("com.apple") && !$0.contains("CrashReporter") })
        #expect(paths.allSatisfy { !$0.hasSuffix("/Kept") })
    }

    @Test func onlyALeftoverVerdictCanMove() throws {
        let fx = try Fixture()
        try fx.file("Library/Application Support/com.example.gone/data", bytes: 9)
        let survey = Residue.survey(home: fx.home, applicationDirectories: [])
        let gone = try #require(survey.candidates.first { $0.displayPath.contains("com.example.gone") })
        #expect(gone.canMove)
        let keep = LeftoverVerdict(kind: .keep, note: "系统还在用")
        #expect(PickedLeftover(gone, verdict: keep) == nil)
        let leftover = LeftoverVerdict(kind: .leftover, note: "应用已经卸了，留下这份数据")
        let picked = try #require(PickedLeftover(gone, verdict: leftover))

        let moves = Residue.move([picked], to: .directory(fx.trash), home: fx.home)
        #expect(moves.count == 1)
        #expect(moves[0].outcome.isConvergedSuccess)
        #expect(!fx.exists("Library/Application Support/com.example.gone"))
    }

    @Test func briefAndVerdictJSONParse() throws {
        let brief = try ModelReviewer.parseBrief(Data(
            #"{"text":"这是 Continue 的代码索引。\n\n删了会重新建，比较费时间。"}"#.utf8
        ))
        #expect(brief.text == "这是 Continue 的代码索引。\n\n删了会重新建，比较费时间。")
        let joined = try ModelReviewer.parseBrief(Data(
            #"{"what":"缓存","dependents":"Safari","ifDeleted":"会重新生成"}"#.utf8
        ))
        #expect(joined.text == "缓存\n\nSafari\n\n会重新生成")

        let verdicts = try ModelReviewer.parseVerdicts(Data(
            #"{"~/Library/Caches/com.gone":{"verdict":"leftover","note":"应用已经不在了"},"x":{"verdict":"nope"}}"#.utf8
        ))
        #expect(verdicts["~/Library/Caches/com.gone"]?.kind == .leftover)
        #expect(verdicts["~/Library/Caches/com.gone"]?.note == "应用已经不在了")
        #expect(verdicts["x"]?.kind == .unsure)
    }

    @Test func jevChoiceBecomesAVerdictAndAWeakLeftoverDoesNot() throws {
        let body = """
        {"model":"jev-1.13.0","answers":{"q0":{"choice":"high","confidence":0.91},"q1":{"choice":"leftover","confidence":0.2}}}
        """
        let answers = try JevJudge.decodeAnswers(Data(body.utf8))
        #expect(answers["q0"]?.choice == "high")
        #expect(answers["q0"]?.confident == true)
        #expect(JevJudge.verdict(from: answers["q1"]!).kind == .unsure)

        let wrapped = """
        {"data":{"answers":{"q0":{"choice":"keep","confidence":0.8}}}}
        """
        let kept = try JevJudge.decodeAnswers(Data(wrapped.utf8))
        #expect(JevJudge.verdict(from: kept["q0"]!).kind == .keep)
    }

    @Test func shortJudgeIdsMapBackOntoCandidates() {
        let candidate = LeftoverCandidate(
            id: "~/Library/Caches/com.example.gone",
            place: .caches,
            displayName: "com.example.gone",
            displayPath: "~/Library/Caches/com.example.gone",
            bytes: 9,
            revealURL: URL(fileURLWithPath: "/tmp/gone"),
            target: nil
        )
        let parsed = ["q0": LeftoverVerdict(kind: .leftover, note: "应用已经不在了")]
        let mapped = ModelReviewer.attach(parsed, to: [(offset: 0, element: candidate)])
        #expect(mapped[candidate.id]?.kind == .leftover)
    }
}

final class PathLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }
    func append(_ path: String) { lock.withLock { stored.append(path) } }
}
