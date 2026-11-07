import Foundation
import Photos

/// 内容分类（全部由本机 Vision 框架离线识别，照片不出手机）
enum ContentCategory: String, CaseIterable, Identifiable {
    case receipt = "发票票据"
    case qrCode = "二维码"
    case document = "文档"
    case screenshot = "截图"
    /// 1.5(25) 把原来的「人物」拆成两张卡。
    ///
    /// 为什么拆：系统**没有**「这是谁」的接口（Vision 只有检测框和关键点，
    /// `VNGenerateFaceFeaturePrintRequest` 不存在），所以按人聚类只能自己拿
    /// `VNGenerateImageFeaturePrintRequest` 做聚类，工作量约等于本版全部改动。
    /// 但「单人的照片 / 多人的照片」用人脸数量就能分，而且正好是用户找照片时
    /// 最常用的两种意图——找自己、找合影。
    ///
    /// 拆分后两类仍然互斥：一张照片的人脸数要么 1、要么 ≥2，不会同时落两桶。
    case singlePerson = "单人照"
    case groupPhoto = "合照"
    case food = "美食"
    case scenery = "风景"
    case pet = "宠物"
    case privacy = "隐私照片"
    case privacyVideo = "隐私视频"
    /// 按素材类型落桶，不是内容判断：所有没被判成隐私视频的视频都在这里。
    /// 放到「其他」前面，是因为用户找视频时是「我要挑大视频」，不是「我要看其他」。
    case video = "视频"
    case other = "其他"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .receipt: return "doc.text.fill"
        case .qrCode: return "qrcode"
        case .document: return "doc.richtext"
        case .screenshot: return "rectangle.dashed"
        case .singlePerson: return "person.fill"
        case .groupPhoto: return "person.3.fill"
        case .food: return "fork.knife"
        case .scenery: return "mountain.2.fill"
        case .pet: return "pawprint.fill"
        case .privacy: return "eye.slash.fill"
        case .privacyVideo: return "video.slash.fill"
        case .video: return "video.fill"
        case .other: return "square.grid.2x2"
        }
    }

    /// 隐私类的判定是概率性的，走的是和别人不一样的路径：
    /// 不进「建议清理」、支持缩略图打码、可以被设置里的开关整体关掉。
    /// 1.5 把「隐私」拆成照片和视频两个类之后，所有特判都必须认这两个，
    /// 所以统一收在这里，别再写 `== .privacy`。
    var isPrivacy: Bool {
        self == .privacy || self == .privacyVideo
    }

    /// 结论的强度：新信号（二维码、以后的聊天截图/手写笔记…）能不能推翻它。
    ///
    /// 这条区分是增量扫描能一直正确下去的前提：
    /// - **强结论**（发票 / 人物 / 美食 / 风景 / 宠物 / 隐私 / 视频）：新信号一律不许改判，
    ///   所以缓存命中就直接用，不用重扫。
    /// - **弱结论**（截图 / 文档 / 其他 / 二维码）：只是「没被更强信号认领」的兜底，
    ///   加了新信号就得重判一遍，否则升级后新分类永远是 0。
    ///
    /// 二维码 1.5(25) 才移进来。以前把它当强结论，结果是：一张印刷发票被通用二维码
    /// 抢判成「二维码」之后，`contentDone` 已经是 true，修好优先级也永远轮不到它重判——
    /// 用户必须删缓存重扫。判据其实很直白：二维码只是「扫到码」这一个证据，
    /// 而优先级是「发票 > 二维码」，能被更强证据推翻的就不算强结论。
    var isSoftCategory: Bool {
        switch self {
        case .screenshot, .document, .other, .qrCode: return true
        default: return false
        }
    }

    /// 从缓存里还原。旧缓存存的是 `"隐私"`（1.4 及更早的类名），
    /// 直接 `ContentCategory(rawValue:)` 会失败并退回 `.other`——
    /// 那会让所有已经判出来的隐私照片在升级后变成「其他」，且 contentDone 已经是 true，
    /// 永远不会重判。所以这里显式认一次旧名字。
    ///
    /// `"人物"` 是 1.5(25) 之前的类名。这里先落到「单人照」，调用方拿到 faceCount
    /// 之后再决定要不要改成「合照」——见 `CachedPhoto.apply(to:)`。
    static func fromCache(_ raw: String) -> ContentCategory {
        if let value = ContentCategory(rawValue: raw) { return value }
        if raw == "隐私" { return .privacy }
        if raw == "人物" { return .singlePerson }
        return .other
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
    /// 人脸数量（320px 小图上数的，快但远景小脸容易漏）
    var faceCount: Int = 0
    /// 1024px 上重数一遍的人脸数（精细复核）。
    ///
    /// 为什么需要两个：分类主链路拿的是 320px 缩略图，一张十人合影缩到这个尺寸后
    /// 每张脸只有十几像素，`VNDetectFaceRectangles` 一个都认不出来——
    /// 这类照片会被判成「单人照」，正是这次拆分最怕的误判。
    /// 复核只在扫描收尾时对人物类跑，结果写进缓存，以后不再重算。
    ///
    /// nil = 还没复核过。判定时优先用它，没有才退回 `faceCount`。
    var faceCountFine: Int? = nil
    /// 人脸框面积之和（占整幅画面的比例，0~1）。
    /// 光有「有没有脸」不够：证件照背景是纸，只有面积够大才说明这是人像而不是「纸上有个小人」。
    var faceArea: Double = 0
    /// 隐私粗筛得分 0~1（人体占比 × 肤色占比，本机算，不上传）
    var privacyScore: Double = 0
    /// 内容识别（分类 / 二维码 / OCR）是否已经跑过。
    /// 增量扫描靠它判断「这张还要不要再认一遍」。
    var contentDone: Bool = false

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

    /// 是不是 Live 照片。
    ///
    /// 特意做成**从 asset 现算**而不是扫描时存一个 Bool：
    /// 它只是 PHAsset 上的一个位掩码，取一次是常数开销；存进缓存反而要在
    /// `CachedPhoto` 里加字段、要给老缓存做可选解码、还要想清楚要不要升信号版本。
    /// 这里零成本，且永远不会和系统状态不一致。
    var isLivePhoto: Bool {
        asset.mediaSubtypes.contains(.photoLive)
    }

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

/// 「看起来一模一样，但原图还在 iCloud，没核对过」的一组照片。
///
/// 1.5(30) 起扫描**不再联网**（用户选的 A 方案）：本地没有原图时只做外观比对
/// （dHash 极近 + 文件大小相同），**不下「完全重复」的结论**，也不进建议删除。
/// 它只是一个「待核对」的线索，用户点了「联网核对」才真的下载原图算 SHA-256。
///
/// 为什么要把这件事单独列出来：以前这种情况直接跳过，用户看到的是「重复 0 组」，
/// 以为相册很干净；实际上只是没联网看。宁可显示「有 3 组待核对」，也不能默认没问题。
struct PendingDuplicateGroup: Identifiable {
    let items: [PhotoItem]

    var id: String {
        return "pending-" + (items.first?.id ?? "empty")
    }

    /// 核对要下载的原图数量（这里就是成员数，每个人都要下）
    var downloadCount: Int { items.count }
}

/// 全量分析结果
struct AnalysisResult {
    var items: [PhotoItem] = []
    var duplicateGroups: [PhotoGroup] = []
    var similarGroups: [PhotoGroup] = []
    /// 看着像完全重复、但原图在 iCloud 上没核对过的组（1.5(30) A 方案）。
    /// 不参与建议删除，只在清理页顶部提示「有 N 组待核对」。
    var unverifiedExactGroups: [PendingDuplicateGroup] = []
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

    /// 预计可释放空间（重复组里每组保留一张，其余可删）
    var reclaimableCount: Int {
        var n = 0
        for g in duplicateGroups { n += max(0, g.items.count - 1) }
        n += blurryItems.count
        n += screenshotItems.count
        return n
    }
}
