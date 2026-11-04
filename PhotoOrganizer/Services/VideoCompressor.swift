import Foundation
import Photos
import AVFoundation

/// 视频压缩：把一段视频转成 720p。
/// 只有「确实变小」时才写入相册新文件，并把原片移到「最近删除」。
final class VideoCompressor {

    static let shared = VideoCompressor()
    private init() {}

    enum Failure: LocalizedError {
        case noVideoResource
        case copyFailed(String)
        case exportUnavailable
        case exportFailed(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoResource: return "这段视频找不到可读取的原始文件"
            case .copyFailed(let m): return "读取原片失败：\(m)"
            case .exportUnavailable: return "系统不支持这个压缩档位"
            case .exportFailed(let m): return "转码失败：\(m)"
            case .saveFailed(let m): return "写入相册失败：\(m)"
            }
        }
    }

    /// 返回 (原大小, 新大小)。若压缩后没变小（new >= old），说明没必要压，
    /// 此时没有写入、也没有删除原片。
    func compress(asset: PHAsset, completion: @escaping (Result<(Int64, Int64), Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let oldSize = PhotoLibraryService.shared.fileSize(of: asset)

                let input = try self.copyOriginal(asset)
                defer { try? FileManager.default.removeItem(at: input) }

                let output = try self.export720p(input)
                defer { try? FileManager.default.removeItem(at: output) }

                let newSize = self.size(of: output)

                // 没变小就别动原片（有些视频本来就是 720p 以下）
                guard oldSize <= 0 || newSize < Int64(Double(oldSize) * 0.97) else {
                    DispatchQueue.main.async { completion(.success((oldSize, newSize))) }
                    return
                }

                try self.saveToLibrary(output, from: asset)
                self.deleteOriginal(asset)

                DispatchQueue.main.async { completion(.success((oldSize, newSize))) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - 步骤

    private func copyOriginal(_ asset: PHAsset) throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let res = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })
                ?? resources.first else {
            throw Failure.noVideoResource
        }

        let ext = (res.originalFilename as NSString).pathExtension
        let name = "src-\(UUID().uuidString)." + (ext.isEmpty ? "mov" : ext)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        PHAssetResourceManager.default().writeData(for: res, toFile: url, options: options) { error in
            failure = error
            sem.signal()
        }
        sem.wait()

        if let failure = failure {
            throw Failure.copyFailed(failure.localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.copyFailed("临时文件没有生成")
        }
        return url
    }

    private func export720p(_ input: URL) throws -> URL {
        let avAsset = AVURLAsset(url: input)
        guard let session = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPreset1280x720) else {
            throw Failure.exportUnavailable
        }

        let type: AVFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        let ext = (type == .mp4) ? "mp4" : "mov"
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).\(ext)")

        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true

        let sem = DispatchSemaphore(value: 0)
        session.exportAsynchronously { sem.signal() }
        sem.wait()

        switch session.status {
        case .completed:
            return out
        case .cancelled:
            throw Failure.exportFailed("已取消")
        default:
            throw Failure.exportFailed(session.error?.localizedDescription ?? "未知原因")
        }
    }

    private func saveToLibrary(_ url: URL, from asset: PHAsset) throws {
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let req = PHAssetCreationRequest.forAsset()
                req.creationDate = asset.creationDate
                req.location = asset.location
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                req.addResource(with: .video, fileURL: url, options: options)
            }
        } catch {
            throw Failure.saveFailed(error.localizedDescription)
        }
    }

    private func deleteOriginal(_ asset: PHAsset) {
        _ = try? PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    private func size(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let n = attrs?[.size] as? NSNumber { return n.int64Value }
        return 0
    }
}
