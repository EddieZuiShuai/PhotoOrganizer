import Foundation
import Photos
import UIKit

/// 核心分析引擎：读图 → 算哈希 → 算清晰度 → 聚类分组。
final class AnalysisEngine {

    static let shared = AnalysisEngine()
    private init() {}

    /// 模糊阈值：拉普拉斯方差低于此值判为模糊（可在设置里调）
    var blurThreshold: Double = 25.0
    /// 相似阈值：dHash 汉明距离小于等于此值判为相似
    var similarDistance: Int = 8

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

                if !isVideo, let thumb = library.thumbnail(for: asset, maxPixel: 256) {
                    item.dHash = self.dHash(from: thumb)
                    item.sharpness = self.sharpness(from: thumb)
                }

                items.append(item)

                if index % 20 == 0 || index == total - 1 {
                    progress(index + 1, total, "正在读取照片")
                }
            }

            result.items = items
            result.videoCount = items.filter { $0.isVideo }.count

            // 2) 分组
            progress(total, total, "正在比对重复与相似")
            let pair = self.groupPhotos(items: items)
            result.duplicateGroups = pair.0
            result.similarGroups = pair.1

            // 3) 模糊 / 截图
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

    // MARK: - 分组

    private func groupPhotos(items: [PhotoItem]) -> ([PhotoGroup], [PhotoGroup]) {
        let photos = items.filter { !$0.isVideo && $0.dHash != nil }
        guard photos.count > 1 else { return ([], []) }

        // 按「尺寸 + 年月日」分桶，避免全量两两比较
        var buckets: [String: [Int]] = [:]
        let cal = Calendar.current
        for (i, item) in photos.enumerated() {
            let day = item.creationDate ?? Date(timeIntervalSince1970: 0)
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            let key = "\(item.pixelWidth)x\(item.pixelHeight)-\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
            buckets[key, default: []].append(i)
        }

        var uf = UnionFind(photos.count)

        for (_, indices) in buckets {
            guard indices.count > 1 else { continue }
            for a in 0..<(indices.count - 1) {
                for b in (a + 1)..<indices.count {
                    let i = indices[a]
                    let j = indices[b]
                    guard let ha = photos[i].dHash, let hb = photos[j].dHash else { continue }
                    let dist = hammingDistance(ha, hb)
                    if dist <= similarDistance {
                        uf.union(i, j)
                    }
                }
            }
        }

        // 汇总成组
        var groupsByRoot: [Int: [Int]] = [:]
        for i in 0..<photos.count {
            groupsByRoot[uf.find(i), default: []].append(i)
        }

        var dupGroups: [PhotoGroup] = []
        var simGroups: [PhotoGroup] = []

        for (_, indices) in groupsByRoot {
            guard indices.count > 1 else { continue }
            let members = indices.map { photos[$0] }

            // 组内若存在 dHash 完全一致，视为「重复」，否则「相似」
            var hasExact = false
            if members.count > 1 {
                outer: for a in 0..<(members.count - 1) {
                    for b in (a + 1)..<members.count {
                        if let ha = members[a].dHash, let hb = members[b].dHash, ha == hb {
                            hasExact = true
                            break outer
                        }
                    }
                }
            }

            if hasExact {
                dupGroups.append(PhotoGroup(items: members, isExactDuplicate: true))
            } else {
                simGroups.append(PhotoGroup(items: members, isExactDuplicate: false))
            }
        }

        dupGroups.sort { $0.items.count > $1.items.count }
        simGroups.sort { $0.items.count > $1.items.count }
        return (dupGroups, simGroups)
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
