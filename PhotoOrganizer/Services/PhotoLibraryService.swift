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
