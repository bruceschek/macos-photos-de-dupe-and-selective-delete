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

        // Fetch images and videos separately
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeHiddenAssets = false
        let imageResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let videoResult = PHAsset.fetchAssets(with: .video, options: fetchOptions)
        let total = imageResult.count + videoResult.count
        print("[Bridge] \(imageResult.count) images + \(videoResult.count) videos = \(total) total")

        // Ingest all metadata in batches (background thread for PHAssetResource).
        // No pre-download pass: hashing pulls thumbnails straight from
        // PhotoKit, which covers iCloud-only assets on demand.
        try await ingestFetchResult(imageResult, total: total, offset: 0)
        try await ingestFetchResult(videoResult, total: total, offset: imageResult.count)

        print("[Bridge] All ingestion done. Starting hashing.")
        try await LocalBackend.shared.startHashing()
        phase = .done
    }

    // MARK: - Private helpers

    private func ingestFetchResult(
        _ result: PHFetchResult<PHAsset>,
        total: Int,
        offset: Int
    ) async throws {
        let count = result.count
        let batchSize = 300
        var cursor = 0

        while cursor < count {
            let end = min(cursor + batchSize, count)
            let assets = (cursor..<end).map { result.object(at: $0) }

            let records: [PhotoRecord] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: assets.map { Self.makeRecord(asset: $0) })
                }
            }

            try await LocalBackend.shared.ingestBatch(records)
            cursor = end
            phase = .ingesting(current: offset + cursor, total: total)
        }
    }

    private nonisolated static func makeRecord(asset: PHAsset) -> PhotoRecord {
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
            // Optimistic until hashing reports otherwise. Determining this at
            // ingest used to mean stat'ing a *guessed* path inside the Photos
            // library package (`originals/<c>/<uuid>.<ext>`) once per asset —
            // hundreds of thousands of filesystem probes into a package no
            // supported API says we may touch, and a guess that silently breaks
            // whenever Apple changes the on-disk layout. `AssetHasher` now
            // reports locality from signals the hashing pass already pays for.
            isLocal: true,
            mediaType: isVideo ? "video" : "image",
            duration: isVideo ? asset.duration : nil
        )
    }
}

enum BridgeError: Error, LocalizedError {
    case notAuthorized(PHAuthorizationStatus)
    var errorDescription: String? {
        "Photos access not authorized. Go to System Settings → Privacy & Security → Photos → Photo Dedup → Full Access."
    }
}
