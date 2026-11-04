import Foundation
import Photos
import UIKit

/// 负责与系统相册打交道：权限、取资产、取缩略图、取文件大小。
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
            // 忽略降质版本，只保留最终图
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
}
