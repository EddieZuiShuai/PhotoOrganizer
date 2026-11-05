import Foundation
import UIKit
import Vision
import ImageIO

/// 本机内容识别：场景分类 + 文字识别 + 人脸计数 + 图像统计。
///
/// 全部使用苹果 Vision 框架，**在手机上离线完成，照片不上传**，也不产生任何费用。
final class ContentAnalyzer {

    static let shared = ContentAnalyzer()
    private init() {}

    /// 图像基础统计
    struct Stats {
        var brightness: Double = 0.5
        var contrast: Double = 0.2
        var edgeDensity: Double = 0.05
    }

    /// 内容识别结果
    struct Content {
        var category: ContentCategory = .other
        var tags: [String] = []
        var ocrHits: [String] = []
        var faceCount: Int = 0
        /// 看起来像「有字的东西」，值得读一次文字
        var textLike: Bool = false
        /// 强文档信号（纸张 / 票据 / 表格…），值得为它重取一张大图再读一次
        var documentLike: Bool = false
        /// 这一次真的跑了 OCR（用来给整库的 OCR 次数计预算）
        var ranOCR: Bool = false
        /// 这一次 OCR 读到的字符数。有字但没命中关键词，往往说明分辨率不够
        var textLength: Int = 0
    }

    // MARK: - 关键词表

    /// 发票/票据强特征词（命中任意 1 个基本可判定）
    private let receiptKeywords: [String] = [
        "发票", "税额", "价税合计", "购买方", "销售方", "开票日期", "发票代码", "发票号码",
        "纳税人识别号", "税率", "合计金额", "小写", "收据", "小票", "账单", "订单号",
        "invoice", "receipt", "subtotal", "grand total", "amount due", "bill to",
        "tax invoice", "order no", "order number", "total amount"
    ]

    /// 文档类特征词
    private let docKeywords: [String] = [
        "合同", "协议", "证明", "通知", "报告", "简历", "身份证", "营业执照", "申请表",
        "contract", "agreement", "certificate", "resume", "report"
    ]

    /// 看起来像「有字的东西」的 Vision 标签，用来决定要不要跑 OCR
    private let textLikeLabels: [String] = [
        "receipt", "invoice", "document", "paper", "text", "menu", "book",
        "business card", "form", "letter", "newspaper", "magazine", "whiteboard",
        "list", "ticket", "banknote", "money", "price tag", "label", "poster",
        "screenshot", "web page", "spreadsheet", "page"
    ]

    /// 强文档信号：命中这些才值得「重取一张大图再读一次字」。
    ///
    /// 故意不收 text / poster / screenshot / web page 这类一命中一大片的标签，
    /// 否则等于每张图都要多取一次 1024px 的大图，扫描时间会被拖垮。
    private let documentLabels: [String] = [
        "receipt", "invoice", "document", "paper", "form", "letter",
        "business card", "ticket", "banknote", "menu", "book",
        "newspaper", "magazine", "spreadsheet", "whiteboard", "price tag"
    ]

    // MARK: - 图像统计（亮度 / 边缘密度）

    func stats(from image: UIImage) -> Stats {
        let w = 64
        let h = 64
        guard let cgImage = image.cgImage else { return Stats() }

        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return Stats() }

        var sum = 0.0
        var sumSq = 0.0
        for v in pixels {
            let d = Double(v) / 255.0
            sum += d
            sumSq += d * d
        }
        let n = Double(pixels.count)
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)

        var edges = 0
        var total = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Int(pixels[y * w + x])
                let r = Int(pixels[y * w + x + 1])
                let d = Int(pixels[(y + 1) * w + x])
                if abs(c - r) > 24 || abs(c - d) > 24 {
                    edges += 1
                }
                total += 1
            }
        }

        return Stats(
            brightness: mean,
            contrast: variance.squareRoot(),
            edgeDensity: total > 0 ? Double(edges) / Double(total) : 0
        )
    }

    // MARK: - 内容识别

    func analyze(image: UIImage, isScreenshot: Bool, allowOCR: Bool = true) -> Content {
        var out = Content()
        guard let cgImage = image.cgImage else { return out }

        let orientation = Self.orientation(from: image.imageOrientation)

        // 第一步：场景分类 + 人脸（一次 perform 完成，省时间）
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let classifyRequest = VNClassifyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([classifyRequest, faceRequest])
        } catch {
            return out
        }

        var labels: [(name: String, conf: Double)] = []
        if let results = classifyRequest.results {
            for obs in results.prefix(12) {
                let conf = Double(obs.confidence)
                if conf >= 0.10 {
                    labels.append((obs.identifier.lowercased(), conf))
                }
            }
        }
        out.faceCount = faceRequest.results?.count ?? 0
        out.tags = labels.prefix(4).map { Self.chineseName(for: $0.name) }

        // 第二步：只在「可能含文字」时才跑 OCR，避免每张都读字
        out.textLike = isScreenshot || labels.contains { item in
            textLikeLabels.contains { item.name.contains($0) }
        }
        out.documentLike = labels.contains { item in
            documentLabels.contains { item.name.contains($0) }
        }
        let needsOCR = allowOCR && out.textLike
        out.ranOCR = needsOCR

        var fullText = ""
        if needsOCR {
            fullText = recognizeText(cgImage: cgImage, orientation: orientation)
            out.textLength = fullText.count
        }

        // 第三步：关键词命中
        var receiptHits: [String] = []
        for key in receiptKeywords where fullText.contains(key.lowercased()) {
            if !receiptHits.contains(key) { receiptHits.append(key) }
        }
        var docHits = 0
        for key in docKeywords where fullText.contains(key.lowercased()) {
            docHits += 1
        }
        out.ocrHits = Array(receiptHits.prefix(4))

        // 第四步：归类（顺序即优先级）
        if !receiptHits.isEmpty {
            out.category = .receipt
        } else if isScreenshot {
            out.category = .screenshot
        } else if docHits > 0 {
            out.category = .document
        } else if hasAny(labels, ["document", "paper", "book", "newspaper", "magazine", "whiteboard", "web page", "spreadsheet", "form", "letter", "page"]) {
            out.category = .document
        } else if hasAny(labels, ["food", "dish", "cuisine", "meal", "dessert", "pizza", "sushi", "cake", "bread", "fruit", "coffee", "menu", "noodle", "hot pot"]) {
            out.category = .food
        } else if hasAny(labels, ["mountain", "beach", "sky", "sunset", "sunrise", "landscape", "sea", "ocean", "forest", "lake", "cloud", "snow", "field", "waterfall", "river"]) {
            out.category = .scenery
        } else if hasAny(labels, ["dog", "cat", "puppy", "kitten", "pet", "animal", "bird", "fish", "hamster"]) {
            out.category = .pet
        } else if out.faceCount > 0 || hasAny(labels, ["person", "people", "portrait", "selfie", "human", "face", "child", "man", "woman", "baby"]) {
            out.category = .person
        } else if hasAny(labels, ["cartoon", "illustration", "clip art", "graphic design", "comic", "drawing", "logo", "emoticon"]) {
            out.category = .meme
        } else {
            out.category = .other
        }

        return out
    }

    // MARK: - 只读字（给大图补读用）

    /// 只跑 OCR、不做分类。
    ///
    /// 为什么需要它：分析主链路拿的是 320px 缩略图。一张 3024×4032 的发票缩到 320px 后，
    /// 上面的字只有 3~6 个像素高，Vision 根本读不出来，于是「发票 / 价税合计 / 税额」
    /// 这些关键词永远命中不了——发票数恒为 0，跟相册里有没有发票无关。
    /// 所以对「看起来像纸」的照片，要重取一张约 1024px 的图，用这个方法再读一次。
    func ocrOnly(image: UIImage) -> (receiptHits: [String], docKeywordHit: Bool, textLength: Int) {
        guard let cgImage = image.cgImage else { return ([], false, 0) }
        let orientation = Self.orientation(from: image.imageOrientation)
        let text = recognizeText(cgImage: cgImage, orientation: orientation)

        var hits: [String] = []
        for key in receiptKeywords where text.contains(key.lowercased()) {
            if !hits.contains(key) { hits.append(key) }
        }
        let docHit = docKeywords.contains { text.contains($0.lowercased()) }
        return (hits, docHit, text.count)
    }

    /// 真正读字的那一段。抽出来是因为「小图初读」和「大图复读」要走同一套参数，
    /// 两边口径不一致的话，关键词命中结果会互相打架。
    private func recognizeText(cgImage: CGImage, orientation: CGImagePropertyOrientation) -> String {
        let ocr = VNRecognizeTextRequest()
        // 只在疑似有文字的图上跑 OCR，所以用 accurate 换准确率，代价可控
        ocr.recognitionLevel = .accurate
        ocr.usesLanguageCorrection = false
        ocr.recognitionLanguages = ["zh-Hans", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([ocr])
        } catch {
            // 读字失败不影响分类，忽略
            return ""
        }

        guard let observations = ocr.results else { return "" }
        var parts: [String] = []
        for obs in observations.prefix(50) {
            if let candidate = obs.topCandidates(1).first {
                parts.append(candidate.string)
            }
        }
        return parts.joined(separator: " ").lowercased()
    }

    // MARK: - 辅助

    private func hasAny(_ labels: [(name: String, conf: Double)], _ keys: [String]) -> Bool {
        for label in labels {
            for key in keys where label.name.contains(key) {
                return true
            }
        }
        return false
    }

    /// 把 Vision 的英文标签翻成中文（按顺序取第一个命中，避免字典乱序）
    private static func chineseName(for identifier: String) -> String {
        let table: [(String, String)] = [
            ("receipt", "票据"),
            ("invoice", "发票"),
            ("business card", "名片"),
            ("menu", "菜单"),
            ("document", "文档"),
            ("paper", "纸张"),
            ("text", "文字"),
            ("screenshot", "截图"),
            ("whiteboard", "白板"),
            ("book", "书"),
            ("food", "食物"),
            ("dish", "菜品"),
            ("dessert", "甜点"),
            ("cake", "蛋糕"),
            ("coffee", "咖啡"),
            ("mountain", "山"),
            ("beach", "海滩"),
            ("sky", "天空"),
            ("sunset", "日落"),
            ("landscape", "风景"),
            ("sea", "海"),
            ("ocean", "海洋"),
            ("forest", "森林"),
            ("lake", "湖"),
            ("snow", "雪"),
            ("dog", "狗"),
            ("cat", "猫"),
            ("pet", "宠物"),
            ("animal", "动物"),
            ("person", "人物"),
            ("people", "人群"),
            ("portrait", "人像"),
            ("selfie", "自拍"),
            ("face", "人脸"),
            ("cartoon", "卡通"),
            ("illustration", "插画"),
            ("poster", "海报"),
            ("building", "建筑"),
            ("car", "车"),
            ("flower", "花"),
            ("plant", "植物"),
            ("sky", "天空")
        ]
        for (key, value) in table where identifier.contains(key) {
            return value
        }
        return identifier.replacingOccurrences(of: "_", with: " ")
    }

    private static func orientation(from value: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch value {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
