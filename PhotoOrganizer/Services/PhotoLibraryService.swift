import Foundation
import Photos
import UIKit
import CryptoKit
import AVFoundation

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
        // ⚠️ 别用 .fastFormat：在部分 iOS 18 模拟器上它会返回 PHPhotosError 3303
        // （image=nil、err=未能完成操作），导致整轮扫描缩略图全 nil、哈希/清晰度/分类
        // 一个都算不出来，清理页每类都是 0，连「逐张过」入口都不显示（UI 回归全挂）。
        // .opportunistic 优先走快速通道、拿不到再回退高质量，两头都不落空。
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false

        var output: UIImage?
        var gotBest = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: maxPixel, height: maxPixel),
            contentMode: .aspectFit,
            options: options
        ) { image, info in
            guard let image = image else { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !degraded {
                output = image
                gotBest = true
            } else if !gotBest {
                // 只拿到降级图也先收下，总比 nil 强——别让一次降级把扫描结果清空。
                output = image
            }
        }
        return output
    }

    /// 列表用的大一点的缩略图
    func listThumbnail(for asset: PHAsset) -> UIImage? {
        return thumbnail(for: asset, maxPixel: 320)
    }

    /// 视频的隐私复核帧。
    ///
    /// 视频没有「一张图」：`thumbnail(for:)` 给的是封面（第一帧），
    /// 而片头经常是黑场、标题卡、或者一段无人的环境镜头。
    /// 只看封面会漏掉真正需要保护的画面，所以在封面判不出来时再补两帧。
    ///
    /// 为什么只补两帧：一次解码 320px 约 20~50 ms，两万张的库里 588 个视频
    /// 全补一遍是 30~60 秒。抽 30% 和 65% 两个点，足够覆盖「整段是同一场景」的常见情况，
    /// 又不会把内容识别的总时长翻倍。取景位置刻意避开片头片尾。
    ///
    /// `appliesPreferredTrackTransform` 必须开：竖拍视频的原始像素是横的，
    /// 不转正的话肤色统计和 Vision 的人脸坐标会差 90°，等于把人脸算到画面外。
    func privacyFrames(for asset: PHAsset, maxPixel: CGFloat = 320) -> [UIImage] {
        guard asset.mediaType == .video else { return [] }
        let duration = asset.duration
        guard duration > 1.0 else { return [] }

        // PHAsset 不是 AVAsset，必须先向 PHImageManager 要一份。
        // 这里是同步等待（带 5 秒上限）：内容识别整段跑在 .utility 队列上，
        // 阻塞它不会卡界面；拿不到就返回空，宁可漏判也不能把整轮扫描拖死。
        // ⚠️ 不要在主线程调这个方法。
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat

        let sem = DispatchSemaphore(value: 0)
        var assetBox: AVAsset?
        PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in
            assetBox = av
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 5) == .success, let avAsset = assetBox else { return [] }

        let generator = AVAssetImageGenerator(asset: avAsset)
        // 竖拍视频的原始像素是横的，不转正的话肤色统计和 Vision 人脸框会差 90°
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

        var frames: [UIImage] = []
        // 30% / 65%：避开片头黑场和片尾，两个点足够覆盖「整段是同一场景」的常见情况
        for ratio in [0.30, 0.65] {
            let time = CMTime(seconds: duration * ratio, preferredTimescale: 600)
            let frameSem = DispatchSemaphore(value: 0)
            var frame: UIImage?
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cg, _, result, _ in
                if result == .succeeded, let cg = cg {
                    frame = UIImage(cgImage: cg)
                }
                frameSem.signal()
            }
            _ = frameSem.wait(timeout: .now() + 5)
            if let frame = frame { frames.append(frame) }
        }
        return frames
    }

    /// 给 OCR 用的清晰大图（同步、高质量、精确缩放）。
    ///
    /// 不能直接用 thumbnail()：那个走 .opportunistic，拿到的是小尺寸快速图，
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

    // MARK: - 隐藏

    /// 把照片/视频放进系统「已隐藏」相簿，或从里面取出来。
    ///
    /// 为什么用系统的而不是自己记一份黑名单：
    /// 1. iOS 16 起「已隐藏」相簿默认要 Face ID 才能打开，等于白拿一层生物锁；
    /// 2. 我们取图本来就是 `includeHiddenAssets = false`（见 `fetchAllAssets`），
    ///    隐藏后它们会自动从 App 里消失，不用另外维护一套过滤逻辑。
    ///
    /// 注意：隐藏不是删除，照片仍在相册里，也不会进「最近删除」。
    func setHidden(_ hidden: Bool, assets: [PHAsset], completion: @escaping (Bool, Error?) -> Void) {
        guard !assets.isEmpty else {
            completion(true, nil)
            return
        }
        PHPhotoLibrary.shared().performChanges({
            for asset in assets {
                // 当前 SDK 里 `PHAssetChangeRequest(for:)` 是非可选的（老文档写的是 `init?`，
                // 照抄会编译报错：cannot use optional chaining on non-optional value）
                PHAssetChangeRequest(for: asset).isHidden = hidden
            }
        }, completionHandler: { success, error in
            completion(success, error)
        })
    }

    /// 系统「已隐藏」相簿里的全部条目。
    ///
    /// 必须显式 `includeHiddenAssets = true`，否则连这个相簿自己都取不到内容——
    /// 这是 PhotoKit 里最容易踩的一处：相簿是对的，开关没开就是空的。
    func fetchHiddenAssets() -> [PHAsset] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumAllHidden, options: nil)
        guard collections.count > 0, let album = collections.firstObject else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = true

        let result = PHAsset.fetchAssets(in: album, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
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

