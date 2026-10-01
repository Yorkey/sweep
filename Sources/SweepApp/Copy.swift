import SwiftUI
import SweepCore

extension SweepCategory {
    var title: String {
        switch self {
        case .cleanable(.userCaches): "用户缓存"
        case .cleanable(.userLogs): "日志"
        case .cleanable(.oldInstallers): "旧安装包"
        case .cleanable(.devCaches): "开发缓存"
        case .cleanable(.browserCaches): "浏览器缓存"
        case .report(.trash): "废纸篓"
        case .report(.largeFiles): "大文件"
        }
    }

    var symbol: String {
        switch self {
        case .cleanable(.userCaches): "archivebox"
        case .cleanable(.userLogs): "doc.text"
        case .cleanable(.oldInstallers): "shippingbox"
        case .cleanable(.devCaches): "hammer"
        case .cleanable(.browserCaches): "globe"
        case .report(.trash): "trash"
        case .report(.largeFiles): "externaldrive"
        }
    }
}

extension RiskLevel {
    var title: String {
        switch self {
        case .safe: "安全"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .critical: "严重"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .low: .teal
        case .medium: .orange
        case .high: .red
        case .critical: .purple
        }
    }
}

extension AssessmentSource {
    var banner: String {
        switch self {
        case .rulesOnly(.noAPIKey): "未配置 API Key，风险等级仅由内置规则评估"
        case .rulesOnly(.reviewPending): "正在用模型复核风险"
        case .rulesOnly(.reviewFailed): "模型复核失败，仍使用规则等级"
        case .modelReviewed: "模型已复核，等级只升不降"
        }
    }

    var symbol: String {
        switch self {
        case .rulesOnly(.noAPIKey): "key.slash"
        case .rulesOnly(.reviewPending): "hourglass"
        case .rulesOnly(.reviewFailed): "exclamationmark.triangle"
        case .modelReviewed: "checkmark.shield"
        }
    }
}

extension Int64 {
    var bytesText: String { formatted(.byteCount(style: .file)) }
}

func confirmationMessage(for order: CleanOrder, bytes: Int64) -> String {
    let base = "将把 \(order.count) 项移到废纸篓（\(bytes.bytesText)）。不会永久删除。"
    return order.allLevels.contains { $0 > .low } ? base + "其中包含中等及以上风险。" : base
}
