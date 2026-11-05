import Foundation
import UIKit
import Vision
import ImageIO
import CoreVideo

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
        /// 人脸框面积之和占画面的比例（0~1）
        var faceArea: Double = 0
        /// 隐私粗筛得分（人体占比 × 肤色占比）
        var privacyScore: Double = 0
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
    ///
    /// `static` 是因为 `category(...)` 是静态方法——判定口径只依赖标签，和实例无关。
    private static let documentLabels: [String] = [
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
        var out = classify(image: image, isScreenshot: isScreenshot)
        guard allowOCR, out.textLike, let cgImage = image.cgImage else { return out }

        let orientation = Self.orientation(from: image.imageOrientation)
        let fullText = recognizeText(cgImage: cgImage, orientation: orientation)
        out.ranOCR = true
        out.textLength = fullText.count
        applyKeywords(fullText, isScreenshot: isScreenshot, to: &out)
        return out
    }

    // MARK: - 只分类（不读字）

    /// 只跑场景分类 + 人脸，一个字都不读。
    ///
    /// 两阶段扫描里，「这张要不要多取一张大图」必须先知道它像不像纸/票，
    /// 而读字是整条链路上最贵的一步。把分类单独拆出来，代价只有几十毫秒。
    func classify(image: UIImage, isScreenshot: Bool) -> Content {
        var out = Content()
        guard let cgImage = image.cgImage else { return out }

        let orientation = Self.orientation(from: image.imageOrientation)

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
        var area = 0.0
        for face in (faceRequest.results ?? []) {
            area += Double(face.boundingBox.width * face.boundingBox.height)
        }
        out.faceArea = min(1, area)
        out.tags = labels.prefix(4).map { Self.chineseName(for: $0.name) }

        out.textLike = isScreenshot || labels.contains { item in
            textLikeLabels.contains { item.name.contains($0) }
        }
        out.documentLike = labels.contains { item in
            Self.documentLabels.contains { item.name.contains($0) }
        }
        out.category = Self.category(
            from: labels,
            faceCount: out.faceCount,
            faceArea: out.faceArea,
            isScreenshot: isScreenshot
        )
        return out
    }

    /// 只看场景标签时的归类（顺序即优先级）。
    /// 读字之后如果命中票据/文档关键词，`applyKeywords` 会把它顶掉。
    ///
    /// **顺序为什么改过**：以前「文档」排在「人物」前面，而文档的判据只是
    /// `paper / book / page` 这类标签命中任意一个。证件照背景是纸、人像手里举着文件，
    /// 都会先命中 paper，人脸的证据根本没机会被用到——这就是「文档组里全是证件照和人像」的根因。
    /// 现在人脸面积够大就直接判人物，文档要等它让完位才有机会。
    private static func category(
        from labels: [(name: String, conf: Double)],
        faceCount: Int,
        faceArea: Double,
        isScreenshot: Bool
    ) -> ContentCategory {
        if isScreenshot { return .screenshot }

        // ① 人像优先：脸够大（>8% 画面）或者有两张以上的脸。
        //    「举着文件的半身照」「证件照」都属于这一类，先抢下来。
        if faceArea >= 0.08 || faceCount >= 2 {
            return .person
        }

        // ② 文档：必须有强信号，且置信度够高。
        //    只认 documentLabels 里那几个「纸面」标签，且要 0.5 以上；
        //    page / web page 这种一命中一大片的词，单独出现不算。
        let strongDoc = labels.contains { item in
            item.conf >= 0.5 && Self.documentLabels.contains { item.name.contains($0) }
        }
        if strongDoc {
            return .document
        }

        if hasAny(labels, ["food", "dish", "cuisine", "meal", "dessert", "pizza", "sushi", "cake", "bread", "fruit", "coffee", "menu", "noodle", "hot pot"]) {
            return .food
        }
        if hasAny(labels, ["mountain", "beach", "sky", "sunset", "sunrise", "landscape", "sea", "ocean", "forest", "lake", "cloud", "snow", "field", "waterfall", "river"]) {
            return .scenery
        }
        if hasAny(labels, ["dog", "cat", "puppy", "kitten", "pet", "animal", "bird", "fish", "hamster"]) {
            return .pet
        }
        if faceCount > 0 || hasAny(labels, ["person", "people", "portrait", "selfie", "human", "face", "child", "man", "woman", "baby"]) {
            return .person
        }
        // 「网图表情」这个分类已经去掉：系统分类模型对 cartoon / illustration 的召回太宽，
        // 正常插画、海报、截图都会被拖进来，用户实际用不上，还污染其他分组。
        return .other
    }

    /// 关键词命中 → 覆盖分类。优先级：票据 > 截图 > 文档 > 标签。
    private func applyKeywords(_ text: String, isScreenshot: Bool, to out: inout Content) {
        var receiptHits: [String] = []
        for key in receiptKeywords where text.contains(key.lowercased()) {
            if !receiptHits.contains(key) { receiptHits.append(key) }
        }
        out.ocrHits = Array(receiptHits.prefix(4))

        if !receiptHits.isEmpty {
            out.category = .receipt
            return
        }
        if isScreenshot {
            out.category = .screenshot
            return
        }
        // 门槛从「命中 1 个」提到 2 个：docKeywords 里全是「合同 / 协议 / 证明」这种
        // 在任何一张带字的照片里都可能出现的词，一个就定死等于把一半生活照拖进文档。
        // 另外脸大的照片不吃这条覆盖——判成文档会把证件照又拉回去。
        var docHits = 0
        for key in docKeywords where text.contains(key.lowercased()) {
            docHits += 1
        }
        if docHits >= 2 && out.faceArea < 0.08 {
            out.category = .document
        }
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

    // MARK: - 发票二维码

    /// 发票二维码解析出来的字段（只留界面上用得着的几项）
    struct InvoiceInfo {
        /// 发票代码（12 位；数电票没有这一栏）
        var code = ""
        /// 发票号码（8 位；数电票 20 位）
        var number = ""
        /// 金额（原样字符串）
        var amount = ""
        /// 开票日期 YYYYMMDD
        var date = ""
        /// 直接塞进界面「识别到：…」那一行
        var hits: [String] = []
    }

    /// 在图片里找发票二维码。
    ///
    /// 为什么值得单独做：纸质发票、电子发票上那枚码是机器印的，不像手写字那样
    /// 受光线和角度影响；而 `VNDetectBarcodes` 是毫秒级的，比 OCR 便宜一个数量级。
    /// 命中就直接判定为发票，连读字都省了。
    func invoiceQR(in image: UIImage) -> InvoiceInfo? {
        guard let cgImage = image.cgImage else { return nil }

        let request = VNDetectBarcodesRequest()
        // 只找发票/票据可能用的三种，不收 code128 之类，省时间也少误判
        request.symbologies = [.qr, .dataMatrix, .pdf417]

        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: Self.orientation(from: image.imageOrientation),
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let results = request.results else { return nil }
        for obs in results {
            guard let payload = obs.payloadStringValue, !payload.isEmpty else { continue }
            if let info = Self.parseInvoicePayload(payload) { return info }
        }
        return nil
    }

    /// 解析国标发票二维码。
    ///
    /// 格式（《电子凭证入账要求 第 2 部分》附录 D）是逗号分隔的一串：
    ///   版本号(01) , 类型(10/11/32…) , 发票代码(12位) , 发票号码(8位 或 数电20位) ,
    ///   金额 , 开票日期(YYYYMMDD) , 校验码后6位(可空) , CRC16(可空)
    ///
    /// 但各家开票平台实际吐出来的字段数并不一致：数电票没有 12 位代码那一栏，
    /// 有的把校验码整段省掉。所以这里**不按固定下标取**，而是按「长得像什么」逐个认，
    /// 只要求：以 01 开头 + 有一个合法日期 + 有一个号码或代码。
    /// 这样网址、WiFi、名片这类二维码一个都不会被误判成发票。
    static func parseInvoicePayload(_ raw: String) -> InvoiceInfo? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 5, parts[0] == "01" else { return nil }

        var ids8: [(index: Int, value: String)] = []
        var longIDs: [String] = []
        var codes: [String] = []
        var amounts: [String] = []

        for (index, token) in parts.enumerated() where index > 0 {
            guard !token.isEmpty, token.allSatisfy({ $0.isNumber || $0 == "." }) else { continue }

            if token.contains(".") {
                if let v = Double(token), v > 0, v < 1_000_000_000 {
                    amounts.append(token)
                }
                continue
            }

            switch token.count {
            case 8:
                ids8.append((index, token))
            case 20:
                longIDs.append(token)
            case 10, 12:
                codes.append(token)
            default:
                break
            }
        }

        // 日期：8 位串里「像日期」的那一个。字段顺序中号码在日期之前，所以取最后一个。
        guard let dateToken = ids8.last(where: { Self.isValidDateToken($0.value) }) else {
            return nil
        }

        var info = InvoiceInfo()
        info.date = dateToken.value
        info.code = codes.first ?? ""
        info.number = longIDs.first
            ?? (ids8.first(where: { $0.index != dateToken.index })?.value ?? "")
        info.amount = amounts.first ?? ""

        // 号码和代码总得有一个，否则「01 + 一个日期」也太巧了
        guard !info.number.isEmpty || !info.code.isEmpty else { return nil }

        var hits = ["二维码发票"]
        if let value = Double(info.amount) {
            hits.append(String(format: "¥%.2f", value))
        }
        if let readable = Self.readableDate(info.date) {
            hits.append(readable)
        }
        info.hits = hits
        return info
    }

    /// YYYYMMDD → 2024-11-20（只做格式转换，不建 Calendar）
    private static func readableDate(_ token: String) -> String? {
        guard token.count == 8 else { return nil }
        let y = token.prefix(4)
        let m = token.dropFirst(4).prefix(2)
        let d = token.suffix(2)
        return "\(y)-\(m)-\(d)"
    }

    /// 只用来认「这 8 位数会不会是开票日期」，所以给一个宽松但足够用的范围。
    private static func isValidDateToken(_ token: String) -> Bool {
        guard token.count == 8, token.allSatisfy({ $0.isNumber }) else { return false }
        guard let year = Int(token.prefix(4)),
              let month = Int(token.dropFirst(4).prefix(2)),
              let day = Int(token.suffix(2)) else { return false }
        return year >= 2000 && year <= 2035 && month >= 1 && month <= 12 && day >= 1 && day <= 31
    }

    // MARK: - 辅助

    private static func hasAny(_ labels: [(name: String, conf: Double)], _ keys: [String]) -> Bool {
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

    // MARK: - 隐私粗筛

    /// 隐私照片粗筛：**人体占比 × 肤色占比**。
    ///
    /// 两条硬约束：全程在本机算，不保存任何中间图、不上传、不进日志。
    /// 只做粗筛，宁可漏也不能错标——误标一张普通照片的代价，比漏掉一张大得多。
    ///
    /// 为什么不是只看肤色：木地板、沙滩、暖光下的墙都能骗过单纯的肤色统计。
    /// 先要求「画面里有成片的人体」（Vision 人体分割），再在这张图上算肤色比例，
    /// 两个条件同时成立才给分。
    func privacyScore(image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }

        // ① 肤色占比。低于 12% 直接出局，连分割都不用跑——省掉大部分开销。
        let skin = skinRatio(cgImage: cgImage)
        guard skin > 0.12 else { return 0 }

        // ② 人体占比
        var bodyRatio = 0.0
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        let seg = VNGeneratePersonSegmentationRequest()
        seg.qualityLevel = .fast
        seg.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try handler.perform([seg])
            if let obs = seg.results?.first {
                bodyRatio = Self.maskRatio(obs.pixelBuffer)
            }
        } catch {
            return 0
        }
        guard bodyRatio > 0.10 else { return 0 }

        // 3.2 是个经验系数：单看肤色约 0.3~0.5（正常露脸照片也会到），
        // 乘上人体占比之后，普通生活照落在 0.05~0.15，才拉得开差距。
        return min(1, skin * bodyRatio * 3.2)
    }

    /// 肤色像素占全图比例。RGB 规则来自常见的肤色检测阈值，粗糙但够用。
    private func skinRatio(cgImage: CGImage) -> Double {
        let side = 96
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return 0 }

        var hit = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i])
            let g = Int(pixels[i + 1])
            let b = Int(pixels[i + 2])
            let mx = max(r, max(g, b))
            let mn = min(r, min(g, b))
            if r > 95, g > 40, b > 20, mx - mn > 15, abs(r - g) > 15, r > g, r > b {
                hit += 1
            }
        }
        return Double(hit) / Double(side * side)
    }

    /// 人体分割 mask 里「是人」的像素占比。每 4 个像素采一个，够用且快。
    private static func maskRatio(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }

        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0 else { return 0 }

        var hit = 0
        var total = 0
        let step = 4
        for y in stride(from: 0, to: h, by: step) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: step) {
                if row[x] > 128 { hit += 1 }
                total += 1
            }
        }
        return total > 0 ? Double(hit) / Double(total) : 0
    }
}
