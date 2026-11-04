import Foundation
import Photos

/// 内容分类（全部由本机 Vision 框架离线识别，照片不出手机）
enum ContentCategory: String, CaseIterable, Identifiable {
    case receipt = "发票票据"
    case document = "文档"
    case screenshot = "截图"
    case person = "人物"
    case food = "美食"
    case scenery = "风景"
    case pet = "宠物"
    case meme = "网图表情"
    case other = "其他"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .receipt: return "doc.text.fill"
        case .document: return "doc.richtext"
        case .screenshot: return "rectangle.dashed"
        case .person: return "person.fill"
        case .food: return "fork.knife"
        case .scenery: return "mountain.2.fill"
        case .pet: return "pawprint.fill"
        case .meme: return "face.smiling"
        case .other: return "square.grid.2x2"
        }
    }
}

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
    /// 清晰度（做过对比度拉伸的拉普拉斯方差），越小越模糊
    var sharpness: Double? = nil
    /// 0~100 的展示分：100 ≈ 本相册的中位清晰度，越低越糊
    var sharpnessScore: Double = -1
    /// 亮度跨度（2%~98% 分位差）。太小说明是纯色/近黑，不参与模糊判定
    var contrastRange: Double = 0
    /// 画面几乎没有细节（近黑 / 近白 / 纯色）
    var isLowDetail: Bool = false
    /// 原图文件大小（字节），用于「完全重复」的快速排除
    var fileSize: Int64 = 0

    // MARK: 内容识别（本机离线）

    /// 内容分类
    var category: ContentCategory = .other
    /// Vision 场景标签（已翻成中文，取前 4 个）
    var contentTags: [String] = []
    /// 文字识别命中的票据关键词
    var ocrHits: [String] = []
    /// 人脸数量
    var faceCount: Int = 0

    // MARK: 图像统计

    /// 平均亮度 0~1，-1 表示没测
    var brightness: Double = -1
    /// 边缘密度 0~1，越低说明画面越「空」
    var edgeDensity: Double = 0

    // MARK: 清理建议

    /// 建议删除分 0~1，越高越值得删
    var cleanupScore: Double = 0
    /// 给出这个分数的原因
    var cleanupReasons: [String] = []
    /// 是否已收藏（收藏的一律不推荐删）
    var isFavorite: Bool = false

    var displayName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: creationDate ?? Date(timeIntervalSince1970: 0))
    }

    var resolutionText: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    var sizeText: String {
        guard fileSize > 0 else { return "" }
        let mb = Double(fileSize) / 1024.0 / 1024.0
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.0f KB", Double(fileSize) / 1024.0)
    }

    var scorePercent: Int {
        Int((cleanupScore * 100).rounded())
    }
}

/// 一组成员（重复组或相似组）
struct PhotoGroup: Identifiable {
    let items: [PhotoItem]
    let isExactDuplicate: Bool

    /// 用首张照片的 id 作为组的稳定标识，避免每次渲染都换 id 导致列表闪动
    var id: String {
        return items.first?.id ?? "empty"
    }
}

/// 全量分析结果
struct AnalysisResult {
    var items: [PhotoItem] = []
    var duplicateGroups: [PhotoGroup] = []
    var similarGroups: [PhotoGroup] = []
    var blurryItems: [PhotoItem] = []
    var screenshotItems: [PhotoItem] = []
    var videoCount: Int = 0

    /// 智能建议：按分数从高到低
    var suggestedItems: [PhotoItem] = []
    /// 按内容分类分组
    var categoryBuckets: [ContentCategory: [PhotoItem]] = [:]

    /// 模糊判定参考值：全库清晰度中位数。界面上的「灵敏度」按它的比例来分档。
    var blurReference: Double = 1

    var photoCount: Int {
        items.filter { !$0.isVideo }.count
    }

    /// 发票票据数量
    var receiptCount: Int {
        (categoryBuckets[.receipt] ?? []).count
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
