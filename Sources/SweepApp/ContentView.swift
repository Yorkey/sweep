import AppKit
import SwiftUI
import SweepCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if model.pane == .clean, let plan = model.plan {
                Label(plan.assessment.banner, systemImage: plan.assessment.symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                Divider()
            }
            if model.pane == .clean { findings } else { residueList }
            Divider()
            footer
        }
        .toolbar {
            ToolbarItem {
                Picker("模块", selection: Bindable(model).pane) {
                    ForEach(WorkspacePane.allCases) { pane in
                        Text(pane.title).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            ToolbarItem {
                if model.pane == .clean {
                    Button {
                        model.scan()
                    } label: {
                        if model.isScanning {
                            Label("正在扫描", systemImage: "hourglass")
                        } else {
                            Label("扫描", systemImage: "magnifyingglass")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.isScanning)
                } else {
                    Button {
                        model.surveyResidue()
                    } label: {
                        if model.isSurveying {
                            Label("正在查找", systemImage: "hourglass")
                        } else {
                            Label("查找残留", systemImage: "magnifyingglass")
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.isSurveying)
                    Button {
                        model.judgeResidue()
                    } label: {
                        if model.isJudging {
                            Label("正在判断", systemImage: "hourglass")
                        } else {
                            Label("让模型判断", systemImage: "sparkles")
                        }
                    }
                    .disabled(model.isJudging || model.residue?.candidates.isEmpty != false)
                }
            }
            ToolbarItem {
                Button {
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .popover(isPresented: $showingSettings) { SettingsForm() }
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                if model.pane == .residue { model.cleanResidue() } else { model.clean() }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: Bindable(model).shownBrief) { shown in
            BriefSheet(shown: shown)
        }
        .alert("无法询问模型", isPresented: explainAlert) {
            Button("好") { model.explainError = nil }
        } message: {
            Text(model.explainError ?? "")
        }
    }

    private var explainAlert: Binding<Bool> {
        Binding(get: { model.explainError != nil }, set: { if !$0 { model.explainError = nil } })
    }

    @ViewBuilder
    private var findings: some View {
        if let plan = model.plan {
            List {
                ForEach(plan.groups) { group in
                    Section {
                        ForEach(group.findings) { finding in
                            FindingRow(finding: finding)
                        }
                    } header: {
                        HStack {
                            Label(group.category.title, systemImage: group.category.symbol)
                            Spacer()
                            Text(group.bytes.bytesText).monospacedDigit()
                        }
                    }
                }
            }
            .overlay {
                if plan.groups.isEmpty && !model.isScanning {
                    ContentUnavailableView("没有发现可清理的内容", systemImage: "sparkles")
                }
            }
        } else if model.isScanning {
            ProgressView("正在扫描").frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView("点击扫描开始", systemImage: "magnifyingglass")
        }
    }

    @ViewBuilder
    private var residueList: some View {
        if let residue = model.residue {
            List {
                if let note = model.residueNote {
                    Text(note).foregroundStyle(.secondary)
                }
                Section {
                    Text("已对照 \(residue.installed.count) 个已安装应用")
                        .foregroundStyle(.secondary)
                    if residue.truncated {
                        Text("只把体积最大的 \(Residue.judgeLimit) 项交给模型。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("候选") {
                    if residue.candidates.isEmpty {
                        Text("没有发现像已卸载应用留下的目录。")
                    }
                    ForEach(residue.candidates) { candidate in
                        ResidueRow(candidate: candidate)
                    }
                }
            }
        } else if model.isSurveying {
            ProgressView("正在对照已安装应用").frame(maxHeight: .infinity)
        } else {
            ContentUnavailableView("查找已卸载应用留下的文件", systemImage: "app.dashed", description: Text("先在本机对照已安装应用，再让模型判断哪些是残留。"))
        }
    }

    private var footer: some View {
        if model.pane == .residue {
            let bytes = model.residuePicked.reduce(Int64(0)) { $0 + $1.bytes }
            return AnyView(footerBar(bytes: bytes, enabled: !model.residuePicked.isEmpty && !model.isCleaning && !model.isJudging))
        }
        let order = model.plan?.order(for: model.selection)
        let bytes = model.plan?.selectedBytes(model.selection) ?? 0
        return AnyView(footerBar(bytes: bytes, enabled: (order?.count ?? 0) > 0 && !model.isCleaning && !model.isScanning))
    }

    private func footerBar(bytes: Int64, enabled: Bool) -> some View {
        HStack {
            Text("已选 \(bytes.bytesText)").monospacedDigit()
            if let moved = model.movedBytes {
                Text("上次移到废纸篓 \(moved.bytesText)").foregroundStyle(.secondary)
            }
            if let skipped = model.plan?.skipped, !skipped.isEmpty {
                Text("跳过 \(skipped.count) 处无法读取的位置")
                    .foregroundStyle(.secondary)
                    .help(skipped.map(\.path).joined(separator: "\n"))
            }
            Spacer()
            if model.isCleaning { ProgressView().controlSize(.small) }
            if model.isExplaining {
                Text("正在询问模型").foregroundStyle(.secondary)
            }
            Button("清理所选") { confirming = true }
                .buttonStyle(.borderedProminent)
                .disabled(!enabled)
        }
        .padding()
    }

    private var confirmationTitle: String {
        if model.pane == .residue {
            let count = model.residuePicked.count
            return "将把 \(count) 项残留移到废纸篓。模型认为这些是已卸载应用留下的。不会永久删除。"
        }
        guard let plan = model.plan else { return "" }
        return confirmationMessage(for: plan.order(for: model.selection), bytes: plan.selectedBytes(model.selection))
    }
}

private struct FindingRow: View {
    @Environment(AppModel.self) private var model
    let finding: Finding

    var body: some View {
        row.contextMenu {
            Button("询问模型") { model.explain(finding) }
                .disabled(model.isExplaining)
            if case .report(let item) = finding {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.revealURL])
                }
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        switch finding {
        case .cleanable(let item):
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: binding(for: item)) {
                    details(name: item.displayName, path: item.displayPath)
                }
                .toggleStyle(.checkbox)
                Spacer()
                trailing(bytes: item.bytes, risk: item.risk)
            }
        case .report(let item):
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "eye").foregroundStyle(.secondary)
                details(name: item.displayName, path: item.displayPath)
                Spacer()
                Text("仅报告").font(.caption).foregroundStyle(.secondary)
                trailing(bytes: item.bytes, risk: item.risk)
            }
        }
    }

    private func binding(for item: Cleanable) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(item) },
            set: { model.selection.set(item.id, selected: $0) }
        )
    }

    private func details(name: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    private func trailing(bytes: Int64, risk: AssessedRisk) -> some View {
        HStack(spacing: 8) {
            Text(bytes.bytesText).monospacedDigit()
            Text(risk.level.title)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(risk.level.tint.opacity(0.2), in: Capsule())
                .foregroundStyle(risk.level.tint)
                .help(risk.modelExplanation.map { "\(risk.rule.reason)\n\($0)" } ?? risk.rule.reason)
        }
    }
}

private struct SettingsForm: View {
    @State private var apiKey = APIKeyStore.load() ?? ""
    @State private var jevKey = APIKeyStore.load(file: "jev-api-key") ?? ""
    @AppStorage(SettingsKey.baseURL) private var baseURL = SettingsKey.defaultBaseURL
    @AppStorage(SettingsKey.model) private var modelName = SettingsKey.defaultModel
    @AppStorage(SettingsKey.jevBaseURL) private var jevBaseURL = SettingsKey.defaultJevBaseURL
    @AppStorage(SettingsKey.jevModel) private var jevModel = SettingsKey.defaultJevModel

    var body: some View {
        Form {
            Section("生成模型") {
                SecureField("API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, newValue in APIKeyStore.save(newValue) }
                TextField("Base URL", text: $baseURL)
                TextField("模型", text: $modelName)
            }
            Section("判断") {
                SecureField("Jev API Key", text: $jevKey)
                    .onChange(of: jevKey) { _, newValue in APIKeyStore.save(newValue, file: "jev-api-key") }
                TextField("Jev Base URL", text: $jevBaseURL)
                TextField("Jev 模型", text: $jevModel)
            }
            Text("填写 Jev 后，扫描复核和残留判断走 Jev。留空则用生成模型。询问说明始终用生成模型，因为 Jev 不写文字。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 420)
    }
}

private struct ResidueRow: View {
    @Environment(AppModel.self) private var model
    let candidate: LeftoverCandidate

    private var verdict: LeftoverVerdict? { model.verdicts[candidate.id] }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if verdict?.kind == .leftover, candidate.canMove {
                Toggle(isOn: selected) {
                    details
                }
                .toggleStyle(.checkbox)
            } else {
                Image(systemName: "eye").foregroundStyle(.secondary)
                details
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(candidate.bytes.bytesText).monospacedDigit()
                Text(verdictLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("询问模型") { model.explain(candidate) }
                .disabled(model.isExplaining)
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([candidate.revealURL])
            }
        }
    }

    private var selected: Binding<Bool> {
        Binding(
            get: { model.residueSelection.contains(candidate.id) },
            set: { on in
                if on { model.residueSelection.insert(candidate.id) }
                else { model.residueSelection.remove(candidate.id) }
            }
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(candidate.displayName)
            Text(candidate.displayPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let verdict, !verdict.note.isEmpty {
                Text(verdict.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var verdictLabel: String {
        if verdict == nil, model.isJudging { return "正在判断" }
        switch verdict?.kind {
        case .leftover: return "残留"
        case .keep: return "仍在使用"
        case .unsure: return "不确定"
        case nil: return "待判断"
        }
    }
}

private struct BriefSheet: View {
    let shown: ShownBrief
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shown.title).font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.body)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var paragraphs: [String] {
        let parts = shown.brief.text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? ["模型没有写出说明。"] : parts
    }
}
