import Foundation
import Photos
import UIKit
import os

/// 核心分析引擎：读图 → 算哈希 → 算清晰度 → 聚类分组。
///
/// 判定口径（重要）：
/// - **完全重复**：原图文件的 SHA-256 一致（字节级完全相同），且尺寸一致。
///   只有拿到「确凿证据」才标重复，避免误判。
/// - **相似**：dHash 汉明距离 ≤ similarDistance，但字节不同。
///   用「星型聚类」（只和种子比），不做传递合并，避免 A 像 B、B 像 C 就把 A/C 并成一组。
final class AnalysisEngine {

    static let shared = AnalysisEngine()
    private init() {}

    /// 模糊判定：现在的口径是「和本相册的中位清晰度比」，
    /// 这个绝对值只作为兜底（低于它的任何照片都不算清晰）。
    var blurThreshold: Double = 25.0
    /// 相似阈值：dHash 汉明距离小于等于此值判为相似
    var similarDistance: Int = 8
    /// 「完全重复」的候选预筛距离：只有哈希非常接近的才会去核对原图字节
    var exactCandidateDistance: Int = 3

    // MARK: - 主流程（两阶段出货）

    /// 扫描分两次交付结果。
    ///
    /// 1. **先出货**：只算「读缩略图就能算出来的东西」——dHash、清晰度、亮度/边缘，
    ///    据此给出重复组、相似组、模糊、截图、建议清理。这一段不含任何 Vision 请求，
    ///    耗时基本只剩解码缩略图，两万张的库也是一分钟级。
    /// 2. **后台补齐**：内容识别（场景分类 + 发票二维码 + OCR）比特征贵一个数量级，
    ///    让它跑在结果页后面，边跑边补，用户不用盯着进度条等六七分钟。
    ///
    /// 代价是缩略图要取两次（PHImageManager 的缓存放不下两万张）。多花这几十秒，
    /// 换来「一分钟就能开始清理」，值。
    func analyze(
        assets: [PHAsset],
        progress: @escaping (_ processed: Int, _ total: Int, _ phase: String) -> Void,
        onQuickResult: ((AnalysisResult) -> Void)? = nil,
        refineProgress: ((_ processed: Int, _ total: Int, _ phase: String) -> Void)? = nil,
        completion: @escaping (AnalysisResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let total = assets.count
            let tStart = CFAbsoluteTimeGetCurrent()

            // ---------- 阶段 1：特征 ----------
            var items = self.featurePass(assets: assets, progress: progress)
            let tFeature = CFAbsoluteTimeGetCurrent() - tStart

            // ---------- 阶段 2：分组 + 打分 → 这里就出货 ----------
            let tGroupStart = CFAbsoluteTimeGetCurrent()
            let grouped = self.groupPass(items: items, progress: progress, total: total)
            let quick = self.assemble(items: items, grouped: grouped, contentReady: false)
            let tGroup = CFAbsoluteTimeGetCurrent() - tGroupStart

            NSLog("[PhotoOrganizer][Scan] 阶段一 %d 张 / %.1fs（读取+特征 %.1fs｜分组+打分 %.1fs）",
                  total, CFAbsoluteTimeGetCurrent() - tStart, tFeature, tGroup)

            if let onQuickResult = onQuickResult {
                DispatchQueue.main.async { onQuickResult(quick) }
            }

            // ---------- 阶段 3：内容识别（后台） ----------
            // 换到 .utility 队列：这时候用户多半正在翻结果页、滚缩略图，
            // 内容识别不该跟界面抢 CPU（userInitiated 是会抢的）。
            let tContentStart = CFAbsoluteTimeGetCurrent()
            let refined = DispatchQueue.global(qos: .utility).sync { () -> [PhotoItem] in
                self.contentPass(items, assets: assets, progress: refineProgress)
            }
            items = refined
            let tContent = CFAbsoluteTimeGetCurrent() - tContentStart

            // ---------- 阶段 4：内容信号回填后重算 ----------
            let final = self.assemble(items: items, grouped: grouped, contentReady: true)

            NSLog("[PhotoOrganizer][Scan] 阶段二 内容识别 %.1fs｜全流程 %.1fs",
                  tContent, CFAbsoluteTimeGetCurrent() - tStart)

            DispatchQueue.main.async {
                completion(final)
            }
        }
    }

    // MARK: - 阶段 1：特征

    /// 缩略图 → dHash / 清晰度 / 亮度 / 边缘密度。一个字都不读。
    private func featurePass(
        assets: [PHAsset],
        progress: @escaping (Int, Int, String) -> Void
    ) -> [PhotoItem] {
        let library = PhotoLibraryService.shared
        let total = assets.count
        var items: [PhotoItem] = []
        items.reserveCapacity(total)

        var tFetch = 0.0   // 取缩略图（解码 + 缩放）
        var tCalc = 0.0    // 哈希 + 清晰度 + 统计
        var noThumb = 0

        for (index, asset) in assets.enumerated() {
            let isVideo = (asset.mediaType == .video)

            // 逐张套自动释放池：PHImageManager 解出来的图、CGContext 都是自动释放对象，
            // 整段跑在一个不返回的闭包里，池子一直不排空的话两万张能攒出几个 GB，
            // 中途被系统 jetsam 掉——表现就是「扫到某个百分比突然闪退，还找不到崩溃日志」。
            autoreleasepool {
                var item = PhotoItem(
                    id: asset.localIdentifier,
                    asset: asset,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    isVideo: isVideo
                )
                item.isFavorite = asset.isFavorite
                item.fileSize = library.fileSize(of: asset)

                if !isVideo {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    let thumb = library.thumbnail(for: asset, maxPixel: 320)
                    tFetch += CFAbsoluteTimeGetCurrent() - t0

                    if let thumb = thumb {
                        let t1 = CFAbsoluteTimeGetCurrent()
                        item.dHash = self.dHash(from: thumb)

                        // 清晰度：先做对比度拉伸再算拉普拉斯方差，
                        // 否则「阴天/室内/夜景」这类低对比照片会被误判成糊片
                        if let detail = self.sharpnessDetail(from: thumb) {
                            item.sharpness = detail.lapVar
                            item.contrastRange = detail.contrast
                            item.isLowDetail = detail.lowDetail
                        }

                        let st = ContentAnalyzer.shared.stats(from: thumb)
                        item.brightness = st.brightness
                        item.edgeDensity = st.edgeDensity
                        tCalc += CFAbsoluteTimeGetCurrent() - t1
                    } else {
                        noThumb += 1
                    }
                }

                items.append(item)
            }

            if index % 25 == 0 || index == total - 1 {
                progress(index + 1, total, "正在读取照片特征")
            }
        }

        NSLog("[PhotoOrganizer][Scan] 特征 %d 张｜取缩略图 %.1fs｜计算 %.1fs｜取不到缩略图 %d 张",
              total, tFetch, tCalc, noThumb)
        return items
    }

    // MARK: - 阶段 2：分组 + 打分

    /// 分组结果。两个阶段共用：内容识别不会改变「谁和谁重复」，
    /// 所以只在阶段 2 算一次，阶段 4 直接复用，不重复读两万张原图。
    private struct Grouped {
        var duplicateGroups: [PhotoGroup]
        var similarGroups: [PhotoGroup]
        var memberIDs: Set<String>
    }

    private func groupPass(
        items: [PhotoItem],
        progress: @escaping (Int, Int, String) -> Void,
        total: Int
    ) -> Grouped {
        progress(total, total, "正在核对完全重复（读取原图，稍慢）")
        let exact = self.findExactGroups(items: items, progress: progress, total: total)
        progress(total, total, "正在比对相似照片")
        let similar = self.findSimilarGroups(items: items, excluding: exact.memberIDs)
        return Grouped(duplicateGroups: exact.groups, similarGroups: similar, memberIDs: exact.memberIDs)
    }

    private func assemble(
        items: [PhotoItem],
        grouped: Grouped,
        contentReady: Bool
    ) -> AnalysisResult {
        var result = AnalysisResult()

        // 清晰度参考值：本相册自己的中位数。只用特征，两个阶段算出来一样。
        var refs: [Double] = []
        refs.reserveCapacity(items.count)
        for it in items where !it.isVideo && !it.isScreenshot && !it.isLowDetail {
            if let s = it.sharpness, s > 0 {
                refs.append(s)
            }
        }
        refs.sort()
        let ref = refs.isEmpty ? 1 : max(1, refs[refs.count / 2])
        result.blurReference = ref

        var scored = items
        for i in scored.indices {
            if let s = scored[i].sharpness {
                scored[i].sharpnessScore = min(100, 100 * s / ref)
            }
        }

        // 分组里存的快照是阶段 2 拍的，内容识别之后要换回最新的那一条，
        // 否则发票在「重复」标签里会显示成「其他」。
        var latest: [String: PhotoItem] = [:]
        if contentReady {
            latest.reserveCapacity(scored.count)
            for it in scored { latest[it.id] = it }
        }
        func refresh(_ groups: [PhotoGroup]) -> [PhotoGroup] {
            guard contentReady else { return groups }
            return groups.map { group in
                PhotoGroup(
                    items: group.items.compactMap { latest[$0.id] },
                    isExactDuplicate: group.isExactDuplicate
                )
            }
        }
        let dupGroups = refresh(grouped.duplicateGroups)
        let simGroups = refresh(grouped.similarGroups)

        let scores = self.buildScores(
            items: scored,
            duplicates: dupGroups,
            similar: simGroups,
            blurReference: ref
        )

        for i in scored.indices {
            if let s = scores[scored[i].id] {
                scored[i].cleanupScore = min(1, max(0, s.score))
                scored[i].cleanupReasons = s.reasons
            }
        }

        result.items = scored
        result.videoCount = scored.filter { $0.isVideo }.count
        result.duplicateGroups = self.applyScores(dupGroups, scores)
        result.similarGroups = self.applyScores(simGroups, scores)

        // 候选池放宽一档，界面上的「宽松/标准/严格」再从这个池子里筛，改灵敏度不用重扫
        result.blurryItems = scored.filter { item in
            guard !item.isVideo, !item.isScreenshot, !item.isLowDetail,
                  let s = item.sharpness, s > 0 else { return false }
            return s < 320 && s / ref < 0.8
        }
        result.screenshotItems = scored.filter { item in
            return !item.isVideo && item.isScreenshot
        }
        result.suggestedItems = scored
            .filter { !$0.isVideo && !$0.isFavorite && $0.cleanupScore >= 0.5 }
            .sorted { $0.cleanupScore > $1.cleanupScore }

        // 内容没跑完就不出分类：否则「其他 22066」会像 bug 一样挂在结果页上
        if contentReady {
            var buckets: [ContentCategory: [PhotoItem]] = [:]
            for item in scored where !item.isVideo {
                buckets[item.category, default: []].append(item)
            }
            result.categoryBuckets = buckets
        }

        return result
    }

    // MARK: - 阶段 3：内容识别

    /// 场景分类 + 发票二维码 + OCR。
    ///
    /// 顺序是「先便宜后贵」：分类（几十毫秒）→ 二维码（几毫秒，命中就结束）
    /// → OCR（几十到几百毫秒）。二维码命中得越多，这一阶段越省时间，
    /// 而且它判得比关键词硬——机器印的码不会因为反光被读错。
    ///
    /// 返回新数组而不是 inout：这样能直接丢到 .utility 队列上跑，不跟界面抢 CPU。
    private func contentPass(
        _ items: [PhotoItem],
        assets: [PHAsset],
        progress: ((Int, Int, String) -> Void)?
    ) -> [PhotoItem] {
        let library = PhotoLibraryService.shared
        var out = items
        let total = min(out.count, assets.count)

        // OCR 整库给一个总预算，用完就只分类、不读字
        let ocrBudget = 3000
        var ocrUsed = 0
        // 「像纸/票」的照片重取 1024px 再判一次（二维码 + OCR）的预算
        let detailDocBudget = 1500
        var detailDocUsed = 0
        // 靠「小图上读到字」兜底的那批：容易一大片，单独卡死
        let detailTextBudget = 200
        var detailTextUsed = 0

        var qrTried = 0
        var qrHits = 0
        var bigCount = 0
        var memSkips = 0
        var memoryTight = false

        var tThumb = 0.0
        var tClassify = 0.0
        var tQR = 0.0
        var tOCR = 0.0
        let start = CFAbsoluteTimeGetCurrent()

        for i in 0..<total {
            // 每 200 张看一眼还剩多少内存。低于 220 MB 就不再取 1024px 大图：
            // 大图 + Vision 是整轮最吃内存的一步，先牺牲它，保住这一轮能跑完。
            if i % 200 == 0 {
                memoryTight = MemoryProbe.availableMB() < 220
            }

            autoreleasepool {
                let item = out[i]
                guard !item.isVideo else { return }
                let asset = assets[i]

                let t0 = CFAbsoluteTimeGetCurrent()
                guard let thumb = library.thumbnail(for: asset, maxPixel: 320) else { return }
                tThumb += CFAbsoluteTimeGetCurrent() - t0

                let t1 = CFAbsoluteTimeGetCurrent()
                let content = ContentAnalyzer.shared.classify(image: thumb, isScreenshot: item.isScreenshot)
                out[i].category = content.category
                out[i].contentTags = content.tags
                out[i].faceCount = content.faceCount
                tClassify += CFAbsoluteTimeGetCurrent() - t1

                // ① 小图上先扫一眼二维码。截图里的发票、离得近拍的发票，320px 也常读得出；
                //    命中就到此为止，既不用取大图也不用读字。
                if content.documentLike || item.isScreenshot {
                    qrTried += 1
                    let t2 = CFAbsoluteTimeGetCurrent()
                    let info = ContentAnalyzer.shared.invoiceQR(in: thumb)
                    tQR += CFAbsoluteTimeGetCurrent() - t2
                    if let info = info {
                        qrHits += 1
                        out[i].category = .receipt
                        out[i].ocrHits = info.hits
                        return
                    }
                }

                // ② 「像纸/票」的照片：重取 1024px，先二维码、再读字。
                //    320px 上发票的字只有 3~6 像素高，读不出「发票/价税合计」，
                //    这是「发票恒为 0」的正解。
                if content.documentLike && !item.isScreenshot {
                    if memoryTight || detailDocUsed >= detailDocBudget {
                        if memoryTight { memSkips += 1 }
                    } else if let big = library.imageForOCR(for: asset, maxPixel: 1024) {
                        detailDocUsed += 1
                        bigCount += 1

                        let t3 = CFAbsoluteTimeGetCurrent()
                        let info = ContentAnalyzer.shared.invoiceQR(in: big)
                        tQR += CFAbsoluteTimeGetCurrent() - t3
                        if let info = info {
                            qrHits += 1
                            out[i].category = .receipt
                            out[i].ocrHits = info.hits
                            return
                        }

                        let t4 = CFAbsoluteTimeGetCurrent()
                        let detail = ContentAnalyzer.shared.ocrOnly(image: big)
                        tOCR += CFAbsoluteTimeGetCurrent() - t4
                        if !detail.receiptHits.isEmpty {
                            out[i].category = .receipt
                            out[i].ocrHits = Array(detail.receiptHits.prefix(4))
                            return
                        }
                        if detail.docKeywordHit && out[i].category == .other {
                            out[i].category = .document
                        }
                    }
                }

                // ③ 其余「有字的东西」：在 320px 小图上读一次（菜单、路牌、聊天截图…）
                if content.textLike && ocrUsed < ocrBudget {
                    ocrUsed += 1
                    let t5 = CFAbsoluteTimeGetCurrent()
                    let detail = ContentAnalyzer.shared.ocrOnly(image: thumb)
                    tOCR += CFAbsoluteTimeGetCurrent() - t5

                    if !detail.receiptHits.isEmpty {
                        out[i].category = .receipt
                        out[i].ocrHits = Array(detail.receiptHits.prefix(4))
                        return
                    }
                    if detail.docKeywordHit && out[i].category == .other && !item.isScreenshot {
                        out[i].category = .document
                    }

                    // 小图上读到了字却没命中票据关键词 —— 很可能是分辨率不够的发票。
                    // 再给一次 1024px 的机会，但这条路径最容易一大片，预算卡得很紧。
                    if detail.textLength >= 20 && !item.isScreenshot
                        && !memoryTight && detailTextUsed < detailTextBudget {
                        if let big = library.imageForOCR(for: asset, maxPixel: 1024) {
                            detailTextUsed += 1
                            bigCount += 1

                            let t6 = CFAbsoluteTimeGetCurrent()
                            let info = ContentAnalyzer.shared.invoiceQR(in: big)
                            tQR += CFAbsoluteTimeGetCurrent() - t6
                            if let info = info {
                                qrHits += 1
                                out[i].category = .receipt
                                out[i].ocrHits = info.hits
                                return
                            }

                            let t7 = CFAbsoluteTimeGetCurrent()
                            let more = ContentAnalyzer.shared.ocrOnly(image: big)
                            tOCR += CFAbsoluteTimeGetCurrent() - t7
                            if !more.receiptHits.isEmpty {
                                out[i].category = .receipt
                                out[i].ocrHits = Array(more.receiptHits.prefix(4))
                            }
                        }
                    }
                }
            }

            if i % 20 == 0 || i == total - 1 {
                progress?(i + 1, total, "正在识别发票与内容分类")
            }
        }

        NSLog("[PhotoOrganizer][Scan] 内容识别 %d 张 / %.1fs｜取图 %.1fs｜分类 %.1fs｜二维码 %.1fs（试 %d 次，命中 %d）｜OCR %.1fs（%d 次，大图 %d 张，因内存跳过 %d 张）",
              total, CFAbsoluteTimeGetCurrent() - start, tThumb, tClassify,
              tQR, qrTried, qrHits, tOCR, ocrUsed, bigCount, memSkips)

        return out
    }

    // MARK: - 清理建议打分

    struct ScoreEntry {
        var score: Double = 0
        var reasons: [String] = []
    }

    /// 把各种信号加起来（0~1）。分数 ≥0.5 才会进「建议清理」。
    private func buildScores(
        items: [PhotoItem],
        duplicates: [PhotoGroup],
        similar: [PhotoGroup],
        blurReference: Double
    ) -> [String: ScoreEntry] {

        var map: [String: ScoreEntry] = [:]

        func add(_ id: String, _ delta: Double, _ reason: String) {
            var entry = map[id] ?? ScoreEntry()
            entry.score += delta
            if !reason.isEmpty && !entry.reasons.contains(reason) {
                entry.reasons.append(reason)
            }
            map[id] = entry
        }

        // 完全重复：每组留第一张，其余高分
        for group in duplicates {
            guard let keeper = group.items.first else { continue }
            for item in group.items.dropFirst() {
                add(item.id, 0.95, "与「\(keeper.displayName)」的文件字节完全相同")
            }
        }

        // 相似组：留最清晰的那张
        for group in similar {
            let best = group.items.max { ($0.sharpness ?? 0) < ($1.sharpness ?? 0) }
            let keeperID = best?.id
            for item in group.items where item.id != keeperID {
                add(item.id, 0.45, "同组里有一张更清晰的，这张是重复拍的")
            }
        }

        for item in items where !item.isVideo {
            // 模糊：只和「本相册自己的中位清晰度」比，避免不同机型/光线条件误伤。
            // 绝对值再卡一道，和界面「标准」档保持一致，免得建议清理里塞进一堆其实还行的照片。
            if let s = item.sharpness, s > 0, !item.isLowDetail, !item.isScreenshot {
                let score = Int(item.sharpnessScore.rounded())
                let ratio = s / max(1, blurReference)
                if ratio < 0.45 && s < 180 {
                    add(item.id, 0.75, "清晰度只有 \(score)/100，比相册里大部分照片糊")
                } else if ratio < 0.7 && s < 290 {
                    add(item.id, 0.3, "清晰度偏低（\(score)/100）")
                }
            }

            // 低信息量：黑屏 / 纯白 / 纯色
            //
            // 截图必须单独走一条：深色模式的截图天生接近全黑，它不是「误拍 / 挡住了镜头」。
            // 旧的写法让一张黑截图同时吃到 0.7（挡住镜头）+ 0.45（系统截图），直接顶到 100%，
            // 理由还自相矛盾——截图不可能是挡镜头拍出来的。现在只给一条诚实的理由。
            if item.isScreenshot {
                if item.brightness >= 0 && item.brightness < 0.05 {
                    add(item.id, 0.55, "暗色截图，几乎全黑，内容很少")
                } else if item.brightness > 0.97 && item.edgeDensity < 0.012 {
                    add(item.id, 0.55, "截图几乎全是纯色，没什么内容")
                } else {
                    add(item.id, 0.45, "系统截图")
                }
            } else if item.brightness >= 0 {
                if item.brightness < 0.05 {
                    add(item.id, 0.7, "接近全黑，像是误拍或挡住了镜头")
                } else if item.brightness > 0.97 {
                    add(item.id, 0.6, "接近纯白，几乎没有内容")
                } else if item.edgeDensity < 0.012 {
                    add(item.id, 0.5, "画面几乎没有细节，像纯色图")
                }
            }

            // 扣分项：这些通常是「要留的」
            if item.category == .receipt {
                add(item.id, -0.45, "")
            }
            if item.faceCount > 0 {
                add(item.id, -0.25, "")
            }
        }

        return map
    }

    private func applyScores(_ groups: [PhotoGroup], _ scores: [String: ScoreEntry]) -> [PhotoGroup] {
        return groups.map { group in
            let newItems = group.items.map { item -> PhotoItem in
                var copy = item
                if let s = scores[item.id] {
                    copy.cleanupScore = min(1, max(0, s.score))
                    copy.cleanupReasons = s.reasons
                }
                return copy
            }
            return PhotoGroup(items: newItems, isExactDuplicate: group.isExactDuplicate)
        }
    }

    // MARK: - 分桶（只按分辨率分，避免同名尺寸跨日期漏判）

    private func candidateBuckets(_ photos: [PhotoItem]) -> [[Int]] {
        var bySize: [String: [Int]] = [:]
        for (i, p) in photos.enumerated() {
            bySize["\(p.pixelWidth)x\(p.pixelHeight)", default: []].append(i)
        }

        var buckets: [[Int]] = []
        for (_, arr) in bySize {
            if arr.count <= 2500 {
                buckets.append(arr)
            } else {
                // 桶太大时再按年份切一刀，控制两两比较量
                var byYear: [Int: [Int]] = [:]
                for i in arr {
                    let year = Calendar.current.component(.year, from: photos[i].creationDate ?? Date(timeIntervalSince1970: 0))
                    byYear[year, default: []].append(i)
                }
                buckets.append(contentsOf: byYear.values)
            }
        }
        return buckets
    }

    // MARK: - 完全重复：原图 SHA-256 逐一核对

    private func findExactGroups(
        items: [PhotoItem],
        progress: @escaping (Int, Int, String) -> Void,
        total: Int
    ) -> (groups: [PhotoGroup], memberIDs: Set<String>) {

        let photos = items.filter { !$0.isVideo && $0.dHash != nil }
        guard photos.count > 1 else { return ([], []) }

        var uf = UnionFind(photos.count)
        var hashCache: [Int: String] = [:]
        var attempted = Set<Int>()
        var hashedCount = 0

        // 读原图算 SHA-256（同一张只算一次）
        func sha(_ i: Int) -> String? {
            if let cached = hashCache[i] { return cached }
            if attempted.contains(i) { return nil }
            attempted.insert(i)

            guard let data = PhotoLibraryService.shared.originalData(of: photos[i].asset) else {
                return nil
            }
            let hex = PhotoLibraryService.shared.sha256Hex(data)
            hashCache[i] = hex
            hashedCount += 1
            if hashedCount % 5 == 0 {
                progress(total, total, "正在核对完全重复（已读 \(hashedCount) 张原图）")
            }
            return hex
        }

        for bucket in candidateBuckets(photos) where bucket.count > 1 {
            for a in 0..<(bucket.count - 1) {
                let i = bucket[a]
                let pi = photos[i]
                guard let hi = pi.dHash else { continue }

                for b in (a + 1)..<bucket.count {
                    let j = bucket[b]
                    let pj = photos[j]
                    guard let hj = pj.dHash else { continue }
                    guard hammingDistance(hi, hj) <= exactCandidateDistance else { continue }

                    // 文件大小不同，直接排除（省掉一次读盘）
                    if pi.fileSize > 0 && pj.fileSize > 0 && pi.fileSize != pj.fileSize {
                        continue
                    }
                    guard let si = sha(i), let sj = sha(j), si == sj else { continue }
                    uf.union(i, j)
                }
            }
        }

        var byRoot: [Int: [Int]] = [:]
        for i in 0..<photos.count {
            byRoot[uf.find(i), default: []].append(i)
        }

        var groups: [PhotoGroup] = []
        var memberIDs = Set<String>()

        for (_, idxs) in byRoot where idxs.count > 1 {
            // 同一连通分量内的成员必然共享同一个 SHA（相等可传递）
            let members = idxs.map { photos[$0] }
            groups.append(PhotoGroup(items: members, isExactDuplicate: true))
            for m in members { memberIDs.insert(m.id) }
        }

        groups.sort { $0.items.count > $1.items.count }
        return (groups, memberIDs)
    }

    // MARK: - 相似：星型聚类（不做传递合并）

    private func findSimilarGroups(items: [PhotoItem], excluding: Set<String>) -> [PhotoGroup] {
        let photos = items.filter {
            !$0.isVideo && $0.dHash != nil && !excluding.contains($0.id)
        }
        guard photos.count > 1 else { return [] }

        var assigned = [Bool](repeating: false, count: photos.count)
        var groups: [PhotoGroup] = []

        for bucket in candidateBuckets(photos) where bucket.count > 1 {
            for a in 0..<bucket.count {
                let i = bucket[a]
                if assigned[i] { continue }
                guard let hi = photos[i].dHash else { continue }

                var members: [Int] = [i]
                for b in 0..<bucket.count where b != a {
                    let j = bucket[b]
                    if assigned[j] { continue }
                    guard let hj = photos[j].dHash else { continue }
                    if hammingDistance(hi, hj) <= similarDistance {
                        members.append(j)
                    }
                }

                if members.count > 1 {
                    for m in members { assigned[m] = true }
                    groups.append(PhotoGroup(items: members.map { photos[$0] }, isExactDuplicate: false))
                }
            }
        }

        groups.sort { $0.items.count > $1.items.count }
        return groups
    }

    // MARK: - 差分哈希

    func dHash(from image: UIImage) -> UInt64? {
        guard let gray = grayscalePixels(from: image, width: 9, height: 8) else { return nil }
        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = gray[row * 9 + col]
                let right = gray[row * 9 + col + 1]
                hash = hash << 1
                if left > right { hash |= 1 }
            }
        }
        return hash
    }

    func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // MARK: - 清晰度（对比度归一化后的拉普拉斯方差）

    struct SharpnessDetail {
        var lapVar: Double
        var contrast: Double
        var meanLuma: Double
        var lowDetail: Bool
    }

    /// 为什么不再直接用「拉普拉斯方差」：
    /// 同一张清楚的夜景/室内照，因为整体对比度低，方差会被压得很小，被误判成糊片。
    /// 所以先按 2%~98% 分位把亮度拉伸到 0~255，再算方差；同时把近黑、近白、纯色单独标出来，
    /// 它们属于「没内容」而不是「没对上焦」。
    func sharpnessDetail(from image: UIImage) -> SharpnessDetail? {
        let w = 160
        let h = 160
        guard let gray = grayscalePixels(from: image, width: w, height: h) else { return nil }

        // 1) 直方图 + 分位数
        var hist = [Int](repeating: 0, count: 256)
        var sum = 0.0
        for v in gray {
            hist[Int(v)] += 1
            sum += Double(v)
        }
        let n = Double(gray.count)
        let meanLuma = sum / n / 255.0

        func percentile(_ p: Double) -> Double {
            let target = max(1, Int(n * p))
            var acc = 0
            for i in 0..<256 {
                acc += hist[i]
                if acc >= target { return Double(i) }
            }
            return 255
        }

        let lo = percentile(0.02)
        let hi = percentile(0.98)
        let contrast = max(0, hi - lo)

        // 近黑 / 近白 / 几乎没对比：属于「没内容」，不参与模糊判定
        if meanLuma < 0.045 || meanLuma > 0.985 || contrast < 8 {
            return SharpnessDetail(lapVar: 0, contrast: contrast, meanLuma: meanLuma, lowDetail: true)
        }

        // 2) 对比度拉伸到 0~255
        let scale = 255.0 / max(contrast, 1)
        var stretched = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let v = (Double(gray[i]) - lo) * scale
            stretched[i] = Float(min(255.0, max(0.0, v)))
        }

        // 3) 拉普拉斯方差
        var s1 = 0.0
        var s2 = 0.0
        var count = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let idx = y * w + x
                let lap = abs(4 * stretched[idx] - stretched[idx - w] - stretched[idx + w]
                              - stretched[idx - 1] - stretched[idx + 1])
                let d = Double(lap)
                s1 += d
                s2 += d * d
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let mean = s1 / Double(count)
        let variance = max(0, s2 / Double(count) - mean * mean)
        return SharpnessDetail(lapVar: variance, contrast: contrast, meanLuma: meanLuma, lowDetail: false)
    }

    // MARK: - 灰度化

    private func grayscalePixels(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let ok: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        return ok ? pixels : nil
    }
}

// MARK: - 并查集

private struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(_ n: Int) {
        parent = Array(0..<n)
        rank = Array(repeating: 0, count: n)
    }

    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra == rb { return }
        if rank[ra] < rank[rb] {
            parent[ra] = rb
        } else if rank[ra] > rank[rb] {
            parent[rb] = ra
        } else {
            parent[rb] = ra
            rank[ra] += 1
        }
    }
}

// MARK: - 内存探针

/// 问系统「我这个进程还能再吃多少内存」。
///
/// `os_proc_available_memory()` 是 iOS 13 起提供的轻量接口（比 task_info 便宜得多），
/// 返回的是「距离本进程内存上限还剩多少字节」。拿不到就返回一个大数：
/// 宁可多跑一次大图补读，也不要因为读不到数值就把功能整段关掉。
enum MemoryProbe {

    static func availableMB() -> Int {
        if #available(iOS 13.0, *) {
            let bytes = os_proc_available_memory()
            if bytes > 0 {
                return Int(bytes / 1024 / 1024)
            }
        }
        return 9999
    }
}
