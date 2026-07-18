import Photos
import Foundation
import Observation
import AppKit

struct PhotoRecord: Encodable {
    let uuid: String
    let localIdentifier: String
    let filename: String
    let originalFilename: String?
    let dateTaken: Double?
    let burstUuid: String?
    let isRaw: Bool
    let isLive: Bool
    let width: Int
    let height: Int
    let isLocal: Bool
    let filePath: String?
    let mediaType: String   // "image" | "video"
    let duration: Double?   // seconds, videos only

    enum CodingKeys: String, CodingKey {
        case uuid, filename, width, height, duration
        case localIdentifier = "local_identifier"
        case originalFilename = "original_filename"
        case dateTaken        = "date_taken"
        case burstUuid        = "burst_uuid"
        case isRaw            = "is_raw"
        case isLive           = "is_live"
        case isLocal          = "is_local"
        case filePath         = "file_path"
        case mediaType        = "media_type"
    }
}

@MainActor
@Observable
final class PhotoLibraryBridge {
    static let shared = PhotoLibraryBridge()

    enum BridgePhase: Equatable {
        case idle
        case enumerating
        case ingesting(current: Int, total: Int)
        case downloading(current: Int, total: Int)
        case done
        case failed(String)
    }

    var phase: BridgePhase = .idle

    func enumerateAndIngest() async throws {
        phase = .enumerating

        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authStatus == .notDetermined {
            let result = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            print("[Bridge] Authorization: \(result.rawValue)")
        }
        let finalStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard finalStatus == .authorized || finalStatus == .limited else {
            throw BridgeError.notAuthorized(finalStatus)
        }

        let libraryURL = Self.findPhotosLibraryURL()
        print("[Bridge] Library: \(libraryURL.path)")

        // Fetch images and videos separately
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        let imageResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let videoResult = PHAsset.fetchAssets(with: .video, options: fetchOptions)
        let total = imageResult.count + videoResult.count
        print("[Bridge] \(imageResult.count) images + \(videoResult.count) videos = \(total) total")

        // Phase 1: ingest all metadata in batches (background thread for PHAssetResource)
        let cloudImageAssets = try await ingestFetchResult(
            imageResult, libraryURL: libraryURL, total: total, offset: 0, trackCloud: true)
        try await ingestFetchResult(
            videoResult, libraryURL: libraryURL, total: total, offset: imageResult.count, trackCloud: false)

        // Phase 2: download 512×512 previews for iCloud-only images so LocalBackend can hash them
        //          Videos are intentionally excluded — no downloads triggered for video
        if !cloudImageAssets.isEmpty {
            print("[Bridge] \(cloudImageAssets.count) iCloud images need thumbnail download")
            let cacheDir = Self.makeCacheDir()
            for (index, (uuid, asset)) in cloudImageAssets.enumerated() {
                phase = .downloading(current: index, total: cloudImageAssets.count)
                let cachePath = cacheDir.appendingPathComponent("\(uuid).jpg").path

                if !FileManager.default.fileExists(atPath: cachePath) {
                    if let img = await requestPreview(for: asset) {
                        Self.saveJPEG(img, to: cachePath)
                    }
                }

                if FileManager.default.fileExists(atPath: cachePath) {
                    try? await LocalBackend.shared.updateFilePath(uuid: uuid, path: cachePath)
                }
            }
            phase = .downloading(current: cloudImageAssets.count, total: cloudImageAssets.count)
        }

        print("[Bridge] All ingestion done. Starting hashing.")
        try await LocalBackend.shared.startHashing()
        phase = .done
    }

    // MARK: - Private helpers

    @discardableResult
    private func ingestFetchResult(
        _ result: PHFetchResult<PHAsset>,
        libraryURL: URL,
        total: Int,
        offset: Int,
        trackCloud: Bool
    ) async throws -> [(String, PHAsset)] {
        var cloudAssets: [(String, PHAsset)] = []
        let count = result.count
        let batchSize = 300
        var cursor = 0

        while cursor < count {
            let end = min(cursor + batchSize, count)
            let assets = (cursor..<end).map { result.object(at: $0) }
            let libURL = libraryURL

            let records: [PhotoRecord] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: assets.map { Self.makeRecord(asset: $0, libraryURL: libURL) })
                }
            }

            if trackCloud {
                for (record, asset) in zip(records, assets) where !record.isLocal {
                    cloudAssets.append((record.uuid, asset))
                }
            }

            try await LocalBackend.shared.ingestBatch(records)
            cursor = end
            phase = .ingesting(current: offset + cursor, total: total)
        }
        return cloudAssets
    }

    // Downloads a 512×512 preview — triggers minimal iCloud download, NOT the full original
    private func requestPreview(for asset: PHAsset) async -> NSImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true   // allowed for images, not called for videos
            options.isSynchronous = false

            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 512, height: 512),
                contentMode: .aspectFit,
                options: options
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                if !resumed { resumed = true; cont.resume(returning: img) }
            }
        }
    }

    private nonisolated static func makeRecord(asset: PHAsset, libraryURL: URL) -> PhotoRecord {
        let localIdentifier = asset.localIdentifier
        let uuid = asset.localIdentifier.components(separatedBy: "/").first
            ?? asset.localIdentifier

        let isVideo = asset.mediaType == .video
        let resources = PHAssetResource.assetResources(for: asset)

        let primary: PHAssetResource?
        if isVideo {
            primary = resources.first(where: { $0.type == .video })
                ?? resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first
        } else {
            primary = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first
        }

        let originalFilename = primary?.originalFilename
        let ext = (originalFilename as NSString?)?.pathExtension.lowercased()
            ?? (isVideo ? "mov" : "jpeg")

        let rawExtensions: Set<String> = ["raw","cr2","cr3","nef","arw","dng","raf","orf","rw2","rw1"]
        let isRaw = !isVideo && rawExtensions.contains(ext)

        let firstChar = String(uuid.prefix(1)).lowercased()
        let candidatePath = libraryURL
            .appendingPathComponent("originals")
            .appendingPathComponent(firstChar)
            .appendingPathComponent("\(uuid).\(ext)")
            .path
        let isLocal = FileManager.default.fileExists(atPath: candidatePath)

        return PhotoRecord(
            uuid: uuid,
            localIdentifier: localIdentifier,
            filename: originalFilename ?? "\(uuid).\(ext)",
            originalFilename: originalFilename,
            dateTaken: asset.creationDate?.timeIntervalSince1970,
            burstUuid: asset.burstIdentifier,
            isRaw: isRaw,
            isLive: !isVideo && asset.mediaSubtypes.contains(.photoLive),
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            isLocal: isLocal,
            filePath: isLocal ? candidatePath : nil,
            mediaType: isVideo ? "video" : "image",
            duration: isVideo ? asset.duration : nil
        )
    }

    private static func saveJPEG(_ image: NSImage, to path: String) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func makeCacheDir() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.bruceschechter.PhotoDedup/thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func findPhotosLibraryURL() -> URL {
        let prefsPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.iApps.plist"
        if let prefs = NSDictionary(contentsOfFile: prefsPath),
           let dbs = prefs["iPhotoRecentDatabases"] as? [String],
           let first = dbs.first {
            if let url = URL(string: first) { return url }
            return URL(fileURLWithPath: first)
        }
        return URL(fileURLWithPath: "\(NSHomeDirectory())/Pictures/Photos Library.photoslibrary")
    }
}

enum BridgeError: Error, LocalizedError {
    case notAuthorized(PHAuthorizationStatus)
    var errorDescription: String? {
        "Photos access not authorized. Go to System Settings → Privacy & Security → Photos → Photo Dedup → Full Access."
    }
}
