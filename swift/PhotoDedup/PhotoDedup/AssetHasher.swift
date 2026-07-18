import Foundation
import Photos
import AVFoundation
import AppKit

/// Hashes assets by sourcing pixels from PhotoKit instead of decoding
/// originals from disk. Photos maintains pre-rendered derivative thumbnails
/// (orientation-applied, cached on disk) for every asset; serving those is
/// the difference between ~6–91 ms of codec work per photo and a small
/// cached read. It also works uniformly for iCloud-only assets, which
/// previously required a separate download-to-Caches pass — and gives
/// cloud videos a poster-frame hash where they formerly got none.
///
/// `@unchecked Sendable`: `PHAsset` instances are immutable snapshot objects
/// and `PHImageManager` is documented thread-safe; the stored dictionary is
/// never mutated after init.
final class AssetHasher: @unchecked Sendable {
    struct HashResult: Sendable {
        let uuid: String
        let primary: String?
        let variants: [String]   // primary first; orientations for images, frames for videos
    }

    private static let thumbnailSize = CGSize(width: 128, height: 128)
    private static let videoFrameFractions = [0.0, 0.25, 0.5, 0.75]

    private let assets: [String: PHAsset]
    private let imageManager = PHImageManager.default()

    init(uuidToIdentifier: [(uuid: String, localIdentifier: String)]) {
        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: uuidToIdentifier.map(\.localIdentifier), options: nil)
        var byIdentifier: [String: PHAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in byIdentifier[asset.localIdentifier] = asset }
        var map: [String: PHAsset] = [:]
        for entry in uuidToIdentifier {
            if let asset = byIdentifier[entry.localIdentifier] { map[entry.uuid] = asset }
        }
        assets = map
    }

    func hash(uuid: String) async -> HashResult {
        guard let asset = assets[uuid] else {
            return HashResult(uuid: uuid, primary: nil, variants: [])
        }
        if asset.mediaType == .video {
            return await hashVideo(uuid: uuid, asset: asset)
        }
        guard let image = await requestThumbnail(asset),
              let hashes = PHash.orientationHashes(cgImage: image),
              let primary = hashes.first
        else {
            return HashResult(uuid: uuid, primary: nil, variants: [])
        }
        return HashResult(uuid: uuid, primary: primary, variants: hashes)
    }

    // MARK: - Images

    private func requestThumbnail(_ asset: PHAsset) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat   // exactly one callback
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true       // small derivative, not the original
            options.isSynchronous = false
            imageManager.requestImage(
                for: asset,
                targetSize: Self.thumbnailSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(
                    returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    // MARK: - Videos

    private func hashVideo(uuid: String, asset: PHAsset) async -> HashResult {
        // Local videos: sample several frames for a temporal signature, so
        // detection doesn't hinge on a single (often black) first frame.
        if let avAsset = await requestLocalAVAsset(asset) {
            let frames = await Self.frameHashes(avAsset, duration: asset.duration)
            if let primary = frames.first {
                return HashResult(uuid: uuid, primary: primary, variants: frames)
            }
        }
        // Cloud-only (or unreadable) videos: Photos' cached poster frame.
        guard let poster = await requestThumbnail(asset),
              let hash = PHash.hash(cgImage: poster)
        else {
            return HashResult(uuid: uuid, primary: nil, variants: [])
        }
        return HashResult(uuid: uuid, primary: hash, variants: [hash])
    }

    /// AVAsset isn't Sendable, so it crosses the callback boundary in an
    /// unchecked box — safe here: the callback hands us a fresh instance
    /// that only this call chain ever touches.
    private struct AVAssetBox: @unchecked Sendable {
        let value: AVAsset?
    }

    private func requestLocalAVAsset(_ asset: PHAsset) async -> AVAsset? {
        let box: AVAssetBox = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = false   // never download originals
            options.deliveryMode = .fastFormat
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: AVAssetBox(value: avAsset))
            }
        }
        return box.value
    }

    private static func frameHashes(_ asset: AVAsset, duration: TimeInterval) async -> [String] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = thumbnailSize
        let times = videoFrameFractions.map {
            CMTime(seconds: duration * $0, preferredTimescale: 600)
        }
        var hashes: [String] = []
        for await result in generator.images(for: times) {
            guard let frame = try? result.image,
                  let hash = PHash.hash(cgImage: frame)
            else { continue }
            if !hashes.contains(hash) { hashes.append(hash) }
        }
        return hashes
    }
}
