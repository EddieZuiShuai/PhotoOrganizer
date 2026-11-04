import Foundation
import Photos

/// 一张照片（或视频）在分析流程中的承载对象。
struct PhotoItem: Identifiable {
    let id: String
    let asset: PHAsset
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isScreenshot: Bool
    let isVideo: Bool

    /// 差分感知哈希（64 位），用于找重复/相似
    var dHash: UInt64? = nil
    /// 清晰度（拉普拉斯方差），越小越模糊
    var sharpness: Double? = nil

    var displayName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: creationDate ?? Date(timeIntervalSince1970: 0))
    }

    var resolutionText: String {
        "\(pixelWidth) × \(pixelHeight)"
    }
}

/// 一组成员（重复组或相似组）
struct PhotoGroup: Identifiable {
    let id = UUID()
    let items: [PhotoItem]
    let isExactDuplicate: Bool
}

/// 全量分析结果
struct AnalysisResult {
    var items: [PhotoItem] = []
    var duplicateGroups: [PhotoGroup] = []
    var similarGroups: [PhotoGroup] = []
    var blurryItems: [PhotoItem] = []
    var screenshotItems: [PhotoItem] = []
    var videoCount: Int = 0

    var photoCount: Int {
        items.filter { !$0.isVideo }.count
    }

    /// 预计可释放空间（重复组里每组保留一张，其余可删）
    var reclaimableCount: Int {
        var n = 0
        for g in duplicateGroups { n += max(0, g.items.count - 1) }
        n += blurryItems.count
        n += screenshotItems.count
        return n
    }
}

enum PhotoCategory: String, CaseIterable, Identifiable {
    case duplicate = "重复"
    case similar = "相似"
    case blurry = "模糊"
    case screenshot = "截图"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .duplicate: return "doc.on.doc"
        case .similar: return "square.stack.3d.up"
        case .blurry: return "camera.filters"
        case .screenshot: return "rectangle.dashed"
        }
    }
}
