import Foundation
import Photos
import UIKit

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

    /// 模糊阈值：拉普拉斯方差低于此值判为模糊
    var blurThreshold: Double = 25.0
    /// 相似阈值：dHash 汉明距离小于等于此值判为相似
    var similarDistance: Int = 8
    /// 「完全重复」的候选预筛距离：只有哈希非常接近的才会去核对原图字节
    var exactCandidateDistance: Int = 3

    // MARK: - 主流程

    func analyze(
        assets: [PHAsset],
        progress: @escaping (_ processed: Int, _ total: Int, _ phase: String) -> Void,
        completion: @escaping (AnalysisResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result = AnalysisResult()
            let total = assets.count
            let library = PhotoLibraryService.shared

            var items: [PhotoItem] = []
            items.reserveCapacity(total)

            // 1) 逐张提取特征
            for (index, asset) in assets.enumerated() {
                let isVideo = (asset.mediaType == .video)

                var item = PhotoItem(
                    id: asset.localIdentifier,
                    asset: asset,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                    isVideo: isVideo
                )

                if !isVideo {
                    item.fileSize = library.fileSize(of: asset)
                    if let thumb = library.thumbnail(for: asset, maxPixel: 256) {
                        item.dHash = self.dHash(from: thumb)
                        item.sharpness = self.sharpness(from: thumb)
                    }
                }

                items.append(item)

                if index % 20 == 0 || index == total - 1 {
                    progress(index + 1, total, "正在读取照片")
                }
            }

            result.items = items
            result.videoCount = items.filter { $0.isVideo }.count

            // 2) 完全重复（读原图字节核对）
            progress(total, total, "正在核对完全重复（读取原图，稍慢）")
            let exact = self.findExactGroups(items: items, progress: progress, total: total)
            result.duplicateGroups = exact.groups

            // 3) 相似（排除已经是完全重复的）
            progress(total, total, "正在比对相似照片")
            result.similarGroups = self.findSimilarGroups(items: items, excluding: exact.memberIDs)

            // 4) 模糊 / 截图
            progress(total, total, "正在挑出模糊与截图")
            result.blurryItems = items.filter { item in
                guard !item.isVideo, let s = item.sharpness else { return false }
                return s < self.blurThreshold
            }
            result.screenshotItems = items.filter { item in
                return !item.isVideo && item.isScreenshot
            }

            DispatchQueue.main.async {
                completion(result)
            }
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

    // MARK: - 清晰度（拉普拉斯方差）

    func sharpness(from image: UIImage) -> Double? {
        let w = 128
        let h = 128
        guard let gray = grayscalePixels(from: image, width: w, height: h) else { return nil }

        var sum = 0.0
        var sumSq = 0.0
        var count = 0

        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(gray[y * w + x])
                let up = Double(gray[(y - 1) * w + x])
                let down = Double(gray[(y + 1) * w + x])
                let left = Double(gray[y * w + x - 1])
                let right = Double(gray[y * w + x + 1])
                let lap = abs(4.0 * c - up - down - left - right)
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }

        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        let variance = sumSq / Double(count) - mean * mean
        return max(0, variance)
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
