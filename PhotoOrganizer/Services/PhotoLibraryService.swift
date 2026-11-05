import Foundation
import Photos
import UIKit
import CryptoKit

/// 负责与系统相册打交道：权限、取资产、取缩略图、算原图哈希、删除。
final class PhotoLibraryService {

    static let shared = PhotoLibraryService()
    private init() {}

    // MARK: - 权限

    func currentStatus() -> PHAuthorizationStatus {
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 是否处于「只授权了部分照片」状态
    func isLimited() -> Bool {
        return currentStatus() == .limited
    }

    // MARK: - 取资产

    /// 拉取相册里全部照片 + 视频（不含隐藏项）
    func fetchAllAssets() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    // MARK: - 缩略图

    /// 同步取一张小缩略图（用于算哈希、算清晰度）
    func thumbnail(for asset: PHAsset, maxPixel: CGFloat = 256) -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        var output: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                return
            }
            if let image = image {
                output = image
            }
        }
        return output
    }

    /// 列表用的大一点的缩略图
    func listThumbnail(for asset: PHAsset) -> UIImage? {
        return thumbnail(for: asset, maxPixel: 320)
    }

    /// 给 OCR 用的清晰大图（同步、高质量、精确缩放）。
    ///
    /// 不能直接用 thumbnail()：那个走 .fastFormat，拿到的是「快速降级图」，
    /// 把它放大到 1024 只是把一张糊图放大，字照样读不出来。
    /// 同理不碰 iCloud：为了补读文字去下载上千张原图，代价太大，读不到就算了。
    func imageForOCR(for asset: PHAsset, maxPixel: CGFloat = 1024) -> UIImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false

        var output: UIImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            if let image = image {
                output = image
            }
        }
        return output
    }

    /// 详情页用的大图（异步，允许从 iCloud 下载）
    func loadImage(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            if let degraded = info?[PHImageResultIsDegradedKey] as? Bool, degraded {
                return
            }
            completion(image)
        }
    }

    // MARK: - 原图数据 / 哈希

    /// 读取照片原始文件数据（用于算「完全重复」的字节哈希）。
    /// 注意：这一步是真实读盘，只对候选照片调用。
    func originalData(of asset: PHAsset) -> Data? {
        let resources = PHAssetResource.assetResources(for: asset)
        let candidate = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type != .pairedVideo })
        guard let resource = candidate else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        var data = Data()
        var failure = false
        let sem = DispatchSemaphore(value: 0)

        PHAssetResourceManager.default().requestData(
            for: resource,
            options: options,
            dataReceivedHandler: { chunk in
                data.append(chunk)
            },
            completionHandler: { error in
                failure = (error != nil)
                sem.signal()
            }
        )
        sem.wait()

        if failure || data.isEmpty { return nil }
        return data
    }

    /// SHA-256（十六进制字符串）
    func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 文件大小

    /// 读取原始文件大小（字节）。失败返回 0。
    func fileSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first else { return 0 }
        if let size = resource.value(forKey: "fileSize") as? Int64 {
            return size
        }
        if let size = resource.value(forKey: "fileSize") as? Int {
            return Int64(size)
        }
        return 0
    }

    // MARK: - 相册列表（筛选用）

    /// 用户自建相册（只返回里面有内容的）
    func fetchUserAlbums() -> [(id: String, title: String, count: Int)] {
        var out: [(id: String, title: String, count: Int)] = []
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]

        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        result.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            if assets.count > 0 {
                out.append((collection.localIdentifier,
                            collection.localizedTitle ?? "未命名相册",
                            assets.count))
            }
        }
        return out
    }

    /// 某个相册里的全部资产 id（只读 id，很快）
    func assetIDs(inAlbum id: String) -> Set<String> {
        let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
        guard let collection = fetched.firstObject else { return [] }

        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var ids = Set<String>()
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            ids.insert(asset.localIdentifier)
        }
        return ids
    }

    // MARK: - 删除

    /// 删除照片。系统会再弹一次确认，删除后进入「最近删除」，30 天内可恢复。
    func delete(assets: [PHAsset], completion: @escaping (Bool, Error?) -> Void) {
        guard !assets.isEmpty else {
            completion(true, nil)
            return
        }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }, completionHandler: { success, error in
            completion(success, error)
        })
    }
}

#if DEBUG
// MARK: - 只在 CI 里跑的自检
//
// 起因：云端模拟器上「18 张照片 / 占用 13.1 MB」都正常，但建议清理、重复、相似、模糊
// 全是 0，占用分布里 18 张也全归「其他」。而 AnalysisEngine 里 dHash、清晰度、内容分类
// 全部包在 `if let thumb = library.thumbnail(for:maxPixel:)` 里面 —— 缩略图取不到，
// 后面所有特征就都是默认值，整个结果页看起来「一片干净」。
//
// 用启动参数 `-PODiag` 触发，把每种请求方式的真实回调写进 Documents/po-diag.txt。
// 正常启动完全不会执行，Release 包里这段代码根本不存在。
enum DebugSelfCheck {

    static func runIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-PODiag") else { return }
        DispatchQueue.global(qos: .utility).async {
            var lines: [String] = []

            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            lines.append("authorization(\(status.rawValue)) " + describe(status))

            let assets = PhotoLibraryService.shared.fetchAllAssets()
            lines.append("assets=\(assets.count)")

            let sample = Array(assets.prefix(5))
            if sample.isEmpty {
                lines.append("相册为空，没什么可测")
                write(lines)
                return
            }

            var thumbOK = 0
            var hashOK = 0
            var sharpOK = 0

            for (i, asset) in sample.enumerated() {
                lines.append("--- [\(i)] \(asset.pixelWidth)x\(asset.pixelHeight) "
                             + "size=\(PhotoLibraryService.shared.fileSize(of: asset))")
                if i == 0 {
                    lines.append("    fastFormat        : " + probe(asset, .fastFormat, network: false))
                    lines.append("    highQualityFormat : " + probe(asset, .highQualityFormat, network: false))
                    lines.append("    opportunistic     : " + probe(asset, .opportunistic, network: false))
                }

                if let thumb = PhotoLibraryService.shared.thumbnail(for: asset, maxPixel: 320) {
                    thumbOK += 1
                    let hash = AnalysisEngine.shared.dHash(from: thumb)
                    let sharp = AnalysisEngine.shared.sharpnessDetail(from: thumb)
                    if hash != nil { hashOK += 1 }
                    if sharp != nil { sharpOK += 1 }
                    lines.append("    thumb=\(Int(thumb.size.width))x\(Int(thumb.size.height)) "
                                 + "cgImage=\(thumb.cgImage == nil ? "nil" : "ok") "
                                 + "dHash=\(hash.map { String($0, radix: 16) } ?? "nil") "
                                 + "sharpness=\(sharp.map { String(format: "%.1f", $0.lapVar) } ?? "nil") "
                                 + "lowDetail=\(sharp?.lowDetail.description ?? "-")")
                } else {
                    lines.append("    thumb=nil  <- 取不到缩略图，后面所有特征都不会算")
                }
            }

            lines.append("汇总：缩略图 \(thumbOK)/\(sample.count)  dHash \(hashOK)/\(sample.count)  清晰度 \(sharpOK)/\(sample.count)")
            write(lines)
        }
    }

    private static func describe(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    /// 同步请求一次缩略图，把回调里的关键信息原样记下来
    private static func probe(_ asset: PHAsset,
                              _ delivery: PHImageRequestOptionsDeliveryMode,
                              network: Bool) -> String {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = delivery
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network

        var notes: [String] = []
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 320, height: 320),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            let error = (info?[PHImageErrorKey] as? NSError)?.localizedDescription ?? "-"
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false
            let size = image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
            notes.append("image=\(size) degraded=\(degraded) cancelled=\(cancelled) "
                         + "inCloud=\(inCloud) err=\(error)")
        }
        if notes.isEmpty { notes.append("回调一次都没调") }
        return notes.joined(separator: " | ")
    }

    private static func write(_ lines: [String]) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("po-diag.txt")
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSLog("[PODiag] wrote diag file at %@", url.path)
    }
}
#endif

